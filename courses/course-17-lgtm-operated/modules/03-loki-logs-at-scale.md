# Loki: Logs at Scale

> **Module 03 · Course 17** — Loki's design is deliberately unusual: it indexes nothing about the content of log lines, only the labels that identify the stream. That constraint makes the write path cheap and forces a discipline at labeling time that most teams discover too late. This module makes you dangerous with Loki before you ever write a label wrong.

Assume you've shipped logs to *something* — whether Splunk, Elasticsearch, or just CloudWatch. The concepts translate; the cost model is different.

---

## What a "stream" is

In Loki, a **stream** is the unique combination of labels that identifies a log source. Every log line belongs to exactly one stream.

```
stream: {namespace="dojo-app", app="backend", container="api"}
         ──────────────────────────────────────────────────────
         this is the index key; Loki stores ONE entry per stream

         │  log lines (timestamped, strictly ordered within the stream)
         ├─ 2024-01-15T10:00:00Z level=info msg="request received" method=GET path=/api/v1/users
         ├─ 2024-01-15T10:00:01Z level=error msg="db timeout" query="SELECT * FROM users"
         └─ 2024-01-15T10:00:02Z level=info msg="request completed" status=200 latency_ms=12
```

The index tells Loki *which chunks* contain data for a given stream. The log content itself — `level=info`, `method=GET`, `latency_ms=12` — is stored as raw text in a **chunk** and is not indexed.

This is the fundamental trade-off: **indexing stream labels is O(1) per push; scanning chunk content is O(bytes scanned)**. A query that can answer entirely from stream labels is fast; a query that must grep all chunks for a given time window is slow.

---

## The storage model: chunks and the index

```
Write path:
  Alloy (push) → Distributor → Ingester
                                  │ buffers log lines in memory per stream
                                  │ flushes a chunk to object storage when:
                                  │   - chunk reaches capacity (256KB uncompressed)
                                  │   - idle flush timer fires (1 min default)
                                  │   - ingester is gracefully shut down
                                  ▼
                          Object Storage
                            <tenant-id>/
                              <stream-fingerprint>/
                                <chunk-id>    ← snappy-compressed log lines

Read path:
  Grafana → Query Frontend → Querier
                               │ 1. query index → stream fingerprints matching label selector
                               │ 2. for each fingerprint → get chunk refs (time-bounded)
                               │ 3. fetch + decompress each chunk from object storage
                               │ 4. apply filter expressions (|= "error", | json, etc.)
                               └─ return matching lines to Grafana
```

The **index** maps `{label=value, ...}` → list of `(chunk-ref, minTime, maxTime)`. Since Loki 2.8, the default is the **TSDB index**, stored alongside chunks in the same object storage bucket — simpler ops than the previous DynamoDB/Cassandra backends.

Chunks are compressed with Snappy (or gzip, configurable). A typical chunk compresses 5–10× — a 256KB uncompressed chunk lands as ~40KB on S3. At $0.023/GB/month S3 pricing, Loki is dramatically cheaper than Elasticsearch for the same raw log volume.

---

## Label cardinality: the trap

Loki's cardinality problem is the inverse of Mimir's but equally damaging.

```
# Good — low cardinality streams (~10 streams for the whole cluster)
{app="api", env="prod"}

# Bad — high cardinality streams
{pod="api-7d9f4b-abc12"}       # N streams per app; pod names change per restart
{request_id="a91f3c..."}       # 1 stream per request = millions of streams/hour
{trace_id="3fa2d1..."}         # same
{path="/api/v1/users/12345"}   # unbounded path parameters
```

Every unique stream is an entry in the index and a separate in-memory structure in the ingester. With 1M active streams, the querier's index is large; with 10M, ingester OOM is likely. The ingester enforces `max_streams_per_user` (default 10k in many deployments) and rejects new streams when exceeded with the error `"too many streams"`.

**The correct model: use stable, low-cardinality labels for streams. Put high-cardinality data (request IDs, trace IDs, user IDs) inside the log line itself, as structured key=value or JSON.**

```
# Log line — high-cardinality data in the line body, not in stream labels
level=info trace_id=3fa2d1 user_id=u991 msg="payment processed" amount_paise=150000
             ^^^^^^^^^^^^^^^^^^^^^^^^^^^── these are in the line, not the stream labels
```

Loki 2.9+ introduced **structured metadata** — a first-class per-line field for high-cardinality data that's stored alongside the chunk but not indexed as a stream label. In Alloy, you emit it via the `loki.write` component's `structured_metadata` block.

---

## Ingestion limits

```yaml
# limits_config in loki.yaml (overridable per tenant via overrides)
limits_config:
  ingestion_rate_mb: 4              # MB/s per tenant; 429 if exceeded
  ingestion_burst_size_mb: 6
  max_streams_per_user: 10000       # "too many streams" when exceeded
  max_line_size: 256kb              # lines larger than this are rejected
  max_entries_limit_per_query: 5000 # max lines returned per log query
  max_chunks_per_query: 2000000
  reject_old_samples: true
  reject_old_samples_max_age: 1w    # lines older than 1w are rejected on push
  max_label_names_per_series: 15    # max label count per stream
  max_label_name_length: 1024
  max_label_value_length: 2048
```

`reject_old_samples` bites teams doing log backfill. If you're shipping historical logs from a batch job, either set `reject_old_samples: false` for that tenant's ingestion window, or use the out-of-order ingestion path introduced in Loki 2.6 (`unordered_writes: true`).

---

## Retention and compaction

Loki retention is configured per-tenant via `limits_config.retention_period`. The **Compactor** runs as a separate component and:

1. Compacts many small chunks into fewer larger ones — reduces object storage LIST and GET overhead at query time.
2. Applies retention: marks chunks whose `maxTime` is older than `retention_period` for deletion.
3. Deletes marked chunks from object storage after `retention_delete_delay`.

```yaml
compactor:
  working_directory: /loki/compactor
  shared_store: s3
  retention_enabled: true           # MUST be true or no deletion ever happens
  retention_delete_delay: 2h
  retention_delete_worker_count: 150

limits_config:
  retention_period: 30d             # global default; overridable per tenant
```

A common mistake: set `retention_period` globally but leave `retention_enabled: false` in the Compactor — logs never get deleted and storage grows without bound. Both flags must be set.

---

## LogQL: the query language

LogQL is a superset of a stream selector. Every query starts with a **stream selector** in `{}` that filters by labels, then optionally pipes the result through filter/parser/aggregation expressions.

### Stream selectors

```logql
{app="api", env="prod"}                 # exact match — returns all lines
{app=~"api|worker"}                     # regex match
{app="api", namespace!="dojo-infra"}    # exclude a label value
```

### Line filters

```logql
{app="api"} |= "error"                  # lines containing "error"
{app="api"} != "healthcheck"            # exclude lines containing healthcheck
{app="api"} |~ "timeout|deadline"       # regex line filter
{app="api"} !~ "GET /metrics"           # exclude regex match
```

### Parsers and field extraction

```logql
# Parse JSON log lines and use extracted fields as label filters
{app="api"} | json | level="error"

# Parse logfmt (key=value pairs in the line body)
{app="api"} | logfmt | status_code >= 500

# Pattern parser — extract fields from an unstructured line format
{app="nginx"}
  | pattern `<ip> - - [<ts>] "<method> <path> HTTP/<ver>" <status> <bytes>`
  | status > 499

# label_format — rename or drop extracted fields
{app="api"} | json | label_format level=severity, path=""
```

### Metric queries (log-derived metrics)

```logql
# Rate of error lines per second (5m rolling window)
rate({app="api"} |= "error" [5m])

# p99 latency from a structured log field
quantile_over_time(0.99,
  {app="api"} | json | unwrap latency_ms [5m]) by (pod)

# Error count per hour by service
sum by (app) (
  count_over_time({namespace="dojo-app"} | logfmt | level="error" [1h])
)

# Bytes ingested per minute, by app
bytes_rate({namespace="dojo-app"} [1m]) by (app)
```

Metric queries transform Loki from a log viewer into a metrics source. If you can't afford a full Prometheus stack for a signal, `rate()` over a filtered stream gives you a reasonable approximation — though it's more expensive to evaluate than a pre-aggregated Prometheus counter.

---

## Multi-tenancy

Same mechanism as Mimir: every push and every query must carry `X-Scope-OrgID`.

```yaml
# Alloy loki.write component
loki.write "default" {
  endpoint {
    url       = "http://loki.dojo-loki.svc.cluster.local:3100/loki/api/v1/push"
    tenant_id = "dojo-tenant"
  }
}
```

```yaml
# Grafana datasource (provisioning YAML)
datasources:
  - name: Loki
    type: loki
    url: http://loki.dojo-loki.svc.cluster.local:3100
    httpHeaderName1: X-Scope-OrgID
    httpHeaderValue1: dojo-tenant
```

Multi-tenant mode is enabled with `auth_enabled: true` in `loki.yaml`. In auth-disabled mode (single tenant, useful in the dojo for simplicity), omit the header — all data lands in the `fake` tenant, and Grafana's datasource needs no header.

---

## Debugging Loki

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `"too many streams"` from Alloy/Promtail | Hit `max_streams_per_user`; likely a high-cardinality label such as pod name or request ID | Audit stream labels: `sum by (app) (count(loki_ingester_streams_created_total{tenant="dojo-tenant"}))`; remove or drop the high-cardinality label from push config; raise limit as a stopgap |
| Ingester OOM | Label explosion — tens of millions of active streams holding per-stream in-memory state | Review stream label design; move high-cardinality data to log line body or structured metadata |
| LogQL returns no results but lines exist in Alloy logs | `reject_old_samples: true` and push carried an old timestamp; or wrong tenant header | Check ingester for `entry too far in the past`; confirm datasource `X-Scope-OrgID` matches the push tenant |
| `context deadline exceeded` for short time ranges | Line filter (content grep) scanning too many chunks; no label restricts the chunk set | Add a low-cardinality label to the stream selector to shrink chunk set; avoid bare `{}` selectors |
| Missing logs — lines in Alloy but absent in Grafana | Alloy forwarding to wrong URL or wrong tenant; Loki returning 4xx/5xx | `kubectl -n dojo-alloy logs ds/alloy \| grep -i 'error\|fail\|reject'`; query `/ready` and `/metrics` on the Loki Service directly |
| Compactor not deleting old data | `retention_enabled: false` in compactor config, or Compactor Deployment not running | `kubectl -n dojo-loki get pod -l app.kubernetes.io/component=compactor`; check logs for `retention is disabled` |
| Out-of-order sample errors | Two Alloy instances pushing the same stream with overlapping timestamps | Enable `unordered_writes: true` per tenant, or ensure each push agent is the sole writer for a given stream |

> **War story.** On the SAP AI Core logging pipeline (100GB+/day), Loki started rejecting pushes with `"too many streams"` six weeks after a new service went to production. The team had configured Alloy to include `pod` and `container` as stream labels — reasonable at 50 pods during testing. After scaling to 2,000 pods across 30 namespaces for the production rollout, the stream count exploded: 2,000 pods × 4 containers each = 8,000 streams for that one service alone, pushing the cluster over the 10,000-stream per-tenant limit. The immediate fix was raising `max_streams_per_user` to 50,000. The real fix, deployed over the next sprint, was removing `pod` from stream labels and moving pod identification into the log line body as structured metadata via Alloy's `loki.process` stage. Query performance improved at the same time — fewer streams meant the querier's index fit in less memory and label lookups were faster. The lesson: label your streams by *service role* (`app`, `namespace`, `env`), not by *instance*. Instance-level cardinality belongs in the line.

---

## Checkpoint

You're ready for the challenges when you can:

1. Explain the difference between a stream label and structured metadata, and name a concrete example of data that belongs in each.
2. Draw the Loki write path from Alloy push to object storage chunk, naming every component and the data format at each stage.
3. Write a LogQL query that: (a) selects only `error`-level lines from `app="api"`, (b) extracts a `latency_ms` field with `| json`, and (c) computes the p99 latency over a 5-minute window grouped by pod.
4. Name the three conditions that trigger an ingester to flush a chunk to object storage.
5. Explain why `{} |= "error"` is expensive and what you should do structurally to make the equivalent query fast.
6. Describe the two config changes required to make Loki actually delete old data (not just stop serving it).
7. Given a `"too many streams"` error, describe the full diagnosis workflow: which metric you check, which Loki log pattern you grep, and what the cardinality reduction strategy is.

➡ Next up: the **Tempo: Distributed Tracing** module — TraceQL, the trace-to-metrics exemplar link, and operating the trace pipeline at scale.
