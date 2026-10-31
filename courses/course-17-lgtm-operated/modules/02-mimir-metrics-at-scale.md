# Mimir: Metrics at Scale

> **Module 02 · Course 17** — Prometheus works until you need multi-tenancy, more than a few months of retention, or more write throughput than a single node can handle. Mimir solves all three. This module maps the exact path a metric sample takes from your Prometheus `remote_write` block to a Grafana panel, and every place you can put a foot wrong along the way.

Assume you already understand Prometheus — scraping, labels, PromQL basics. We're going deep on what Mimir adds and why the architecture is shaped the way it is.

---

## The write path

A metric sample enters Mimir via **remote write** — the Prometheus protocol where every scraped sample is pushed to an HTTP endpoint rather than stored locally.

```
Prometheus / Alloy
  remote_write:
    url: http://mimir:8080/api/v1/push
    headers:
      X-Scope-OrgID: dojo-tenant    # multi-tenancy — every write must carry this

         │
         ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Distributor                                                         │
│  • validates labels (max count, name/value length)                  │
│  • deduplicates HA pairs (only forwards from the elected replica)   │
│  • shards series by {tenant + label-hash} → ingester ring           │
│  • replicates to replication_factor ingesters (default: 3)          │
└─────────────────────────────────────────────────────────────────────┘
         │ writes to 3 ingesters in the ring (consistent hashing)
         ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Ingester (StatefulSet)                                              │
│  • stores samples in memory + WAL (crash recovery)                  │
│  • accumulates a 2-hour TSDB block, then flushes to object storage  │
│  • serves queries for the "hot" window (recent <2h data)            │
└─────────────────────────────────────────────────────────────────────┘
         │ block flush every 2h
         ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Object Storage (S3 / GCS / MinIO)                                   │
│  • immutable TSDB blocks: chunks/ + index + meta.json + tombstones  │
└─────────────────────────────────────────────────────────────────────┘
```

The WAL protects against ingester crashes. On restart, the ingester replays the WAL and rejoins the ring before accepting new writes. The WAL path must be on a persistent volume — ephemeral ingesters lose in-flight samples that haven't flushed yet.

---

## The read path

```
Grafana
  datasource query (PromQL)
         │
         ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Query Frontend                                                      │
│  • authenticates tenant (X-Scope-OrgID)                             │
│  • splits long time ranges into per-day sub-queries                 │
│  • caches results (optional Redis / Memcached)                      │
│  • queues sub-queries to Scheduler                                  │
└─────────────────────────────────────────────────────────────────────┘
         │ dispatches sub-queries
         ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Querier                                                             │
│  • fans out to ALL ingesters (hot data)                             │
│  • fans out to Store-Gateways (cold data, >2h after flush)          │
│  • merges + deduplicates overlapping replica results                │
│  • executes PromQL on the merged series                             │
└─────────────────────────────────────────────────────────────────────┘
    │ hot (<2h)          │ cold (>2h)
    ▼                    ▼
Ingesters          Store-Gateway
                   • lazy-loads block index shards from object storage
                   • caches index in memory (bucket index)
                   • streams chunk data to querier
```

The query frontend's **time-range splitting** is why a 30-day range query doesn't time out on large clusters: it becomes 30 1-day sub-queries running in parallel across multiple queriers. If you're seeing slow queries, check whether the query frontend is actually splitting — the metric `cortex_query_frontend_split_queries_total` tells you.

---

## Multi-tenancy: X-Scope-OrgID

Every API call in Mimir must carry the `X-Scope-OrgID` header. Without it:

- Writes are rejected with `400 Bad Request: no org id`.
- Queries return `401` or land on a synthetic `anonymous` tenant.

In the dojo, every `remote_write` stanza and every Grafana datasource carries this header:

```yaml
# Prometheus / Alloy remote_write
remote_write:
  - url: http://mimir.dojo-mimir.svc.cluster.local:8080/api/v1/push
    headers:
      X-Scope-OrgID: dojo-tenant

# Grafana datasource (provisioning YAML)
datasources:
  - name: Mimir
    type: prometheus
    url: http://mimir.dojo-mimir.svc.cluster.local:8080/prometheus
    httpHeaderName1: X-Scope-OrgID
    httpHeaderValue1: dojo-tenant
```

Per-tenant limits live under `limits:` in `mimir.yaml`. The most important ones:

```yaml
limits:
  ingestion_rate: 10000            # samples/sec; 429 if exceeded
  ingestion_burst_size: 200000
  max_label_names_per_series: 30
  max_label_value_length: 1024
  max_global_series_per_user: 1500000   # total active series ceiling per tenant
  max_global_series_per_metric: 50000   # per-metric-name ceiling
  max_fetched_chunks_per_query: 2000000
  max_query_lookback: 0                 # 0 = unlimited; set e.g. 30d to enforce retention
```

These are the knobs you'll tune in the challenges. Exceeding them produces `429 Too Many Requests` with a body that names exactly which limit was hit.

---

## Blocks storage

Mimir uses the **Prometheus TSDB block format** on object storage. Each block covers a 2-hour window:

```
<block-ulid>/
  chunks/
    000001          # raw compressed sample data (one or more chunk files)
  index             # postings + series label index (searched by store-gateway)
  meta.json         # minTime, maxTime, stats, compaction level, sources
  tombstones        # deleted series markers (consumed by compactor)
```

The **Compactor** runs as its own component and:

1. Merges small 2h blocks into larger 24h, then 7-day blocks — reduces object storage LIST and GET call overhead at query time.
2. Applies tombstones to actually delete series marked for deletion.
3. De-duplicates across HA replica blocks.

Compaction is background work and does not affect write availability. But if the compactor falls behind (e.g., it crashed for a day), query performance degrades because the querier must merge many small 2h blocks instead of a few large blocks. Monitor `cortex_compactor_runs_completed_total` and `cortex_compactor_blocks_cleaned_total`.

---

## HA pairs and deduplication

When you run two Prometheus instances scraping the same targets (for HA), both send the same series to Mimir. Without deduplication, you'd store every sample twice and queries would return doubled values.

Mimir deduplicates at the **distributor** using a KV-backed HA tracker:

```yaml
# mimir.yaml
ha_tracker:
  enable_ha_tracker: true
  kvstore:
    store: memberlist   # or consul/etcd for production

# each Prometheus must carry cluster + replica external labels
global:
  external_labels:
    cluster: prod
    __replica__: replica-0   # replica-1 on the standby instance
```

The distributor elects one replica per `cluster` label value and forwards only its samples. The standby's samples are counted but dropped. On failover, the distributor detects a gap from the elected replica and re-elects within `ha_tracker.failover_timeout` (default 30s). The metric `cortex_ha_tracker_elected_replica_changes_total` fires on each election change — alert on it.

---

## Cardinality and why it's your biggest operational risk

**Cardinality** = the number of unique label combinations active at any one time. Each unique combination is one time-series in ingester memory and one entry in the block index.

```
# Low cardinality — fine
http_requests_total{method="GET", status="200"}   # ~10 combinations max

# High cardinality — disaster
http_requests_total{user_id="a91f3c...", path="/api/v1/users/a91f3c..."}
# 100k users × 1000 unique paths = 100M active series → OOM
```

The rule: **never use high-cardinality values (user IDs, trace IDs, path parameters, full error messages) as label values.** Put them in log lines or trace span attributes instead — the cost model there is different (they're not indexed per unique value).

Diagnose cardinality before it hits the limit:

```bash
# Top label names by series count, for a specific tenant
curl -s 'http://mimir.dojo-mimir.svc.cluster.local:8080/api/v1/cardinality/label_names' \
  -H 'X-Scope-OrgID: dojo-tenant' | python3 -I -m json.tool

# Active series count per metric name (top offenders)
curl -s 'http://mimir.dojo-mimir.svc.cluster.local:8080/api/v1/cardinality/active_series?selector={}' \
  -H 'X-Scope-OrgID: dojo-tenant'
```

Or use `mimirtool` from inside the cluster:

```bash
mimirtool analyze prometheus \
  --address=http://mimir.dojo-mimir.svc.cluster.local:8080 \
  --id=dojo-tenant
```

---

## Configuring remote_write correctly

The `remote_write` stanza has knobs that matter for reliability and throughput. Defaults leave you vulnerable to queue saturation:

```yaml
remote_write:
  - url: http://mimir.dojo-mimir.svc.cluster.local:8080/api/v1/push
    headers:
      X-Scope-OrgID: dojo-tenant
    queue_config:
      max_samples_per_send: 2000       # batch size
      batch_send_deadline: 5s          # max time to wait before sending a partial batch
      min_shards: 4                    # parallel send goroutines — increase for high throughput
      max_shards: 200
      capacity: 2500                   # in-memory queue depth per shard
    metadata_config:
      send: true
      send_interval: 1m
```

The metric `prometheus_remote_storage_queue_highest_sent_timestamp_seconds` lagging behind `prometheus_remote_storage_samples_pending` is the first sign of write-path congestion. If the lag grows over time, add shards or raise `capacity`.

---

## Debugging Mimir

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `429 Too Many Requests` on remote_write | Tenant hit `ingestion_rate` or `max_global_series_per_user` | Check distributor logs for which limit; raise the limit or reduce cardinality first |
| `out of order sample` in Prometheus remote_write logs | Clock drift between Prometheus instances, or two instances writing the same series without HA dedup | Enable `ha_tracker`; ensure each instance carries a unique `__replica__` external label; sync clocks via NTP |
| Slow PromQL (>5s for short ranges) | Querier fetching too many chunks; no query result cache; uncompacted blocks | Enable query result caching (Redis/Memcached); verify compactor is running; add `max_fetched_chunks_per_query` limit |
| Ingester stuck in `JOINING` and never `ACTIVE` | Crashed mid-token-registration; stale ring entry in memberlist/KV | Delete the stuck ingester pod; ring converges after `ring_heartbeat_timeout`; force-remove with `mimirtool` ring commands if needed |
| Block upload failing; store-gateway 404 on new blocks | Object storage bucket doesn't exist, or wrong bucket name in config | `kubectl -n dojo-mimir logs deploy/mimir-ingester \| grep -i upload`; verify bucket with `mc ls minio/mimir-blocks` |
| Grafana shows "no data" but Prometheus is writing successfully | Datasource missing `X-Scope-OrgID`, or wrong tenant name | Add header to datasource; confirm data with `curl -H 'X-Scope-OrgID: dojo-tenant' .../api/v1/labels` |
| Compactor not running after many days; query latency climbs | Compactor Deployment scaled to 0 or crashing silently | `kubectl -n dojo-mimir get deploy mimir-compactor`; check logs for bucket access errors |

> **War story.** A Mimir tenant at Grafana Labs started hitting `429 ingestion_rate_exceeded` during one specific business hour each day. The ingestion rate was well under the limit for the other 23 hours. Digging into the Alloy configuration revealed that one pipeline had been configured with `batch_send_deadline: 30s` — so when a 45-minute network blip caused a reconnect, Alloy drained the backlogged queue in a 30-second burst: 45 min × ~50k series × 2 samples/min / 30s = a spike 3× over the limit. The fix was lowering `batch_send_deadline` to `5s` and raising `min_shards` to 4, smoothing the burst into a steady stream. The metric `prometheus_remote_storage_queue_highest_sent_timestamp_seconds` lagging behind `_latest_sent_timestamp_seconds` was visible for over an hour before the 429s appeared — that lag is now a warning alert, not an afterthought.

---

## Checkpoint

You're ready for the challenges when you can:

1. Trace a single metric sample from Prometheus `remote_write` through distributor → ingester → object storage block, naming what happens at each hop.
2. Explain what happens to the standby HA replica's samples when the HA tracker is active, and which metric tells you an election change occurred.
3. State what a TSDB block's `meta.json` contains and why the compactor needs it.
4. Identify from a `429` response body which specific limit was exceeded and name the config key to raise it.
5. Write a `curl` command (with the correct tenant header) that returns the top cardinality contributors for a Mimir tenant.
6. Explain why a label value like `user_id=xyz` causes exponential cardinality growth compared to tracking user counts in a LogQL `count_over_time` query.
7. Describe the `prometheus_remote_storage_queue_highest_sent_timestamp_seconds` metric and what it tells you about write-path health.

➡ Next up: **Loki: Logs at Scale** — the chunks-and-index model, LogQL in depth, and the label cardinality trap.
