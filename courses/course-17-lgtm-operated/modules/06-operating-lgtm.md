# Operating LGTM in Production

> **Module 06 · Course 17** — Deploying LGTM is a morning's work. Running it for 12 months without it becoming a reliability liability, a cost surprise, or a cardinality timebomb is the SRE's actual job. This module is deliberately Grafana-Labs-shaped: multi-tenancy, object storage lifecycle, retention, compaction, the observability-of-observability problem, and the SLO conversation nobody has until something breaks.

This is the "daily life" module. Every section is something that pages someone at Grafana Labs. Skip nothing.

---

## Multi-Tenancy and Per-Tenant Limits

LGTM is built for multi-tenant operation. The architectural guarantee is **data isolation by tenant ID** — one tenant cannot read another's data, and one tenant going wild cannot OOM the whole cluster.

### How tenancy works

Every request to Loki, Tempo, or Mimir carries an `X-Scope-OrgID` header. The distributor/ingester/querier use this to namespace all storage and all in-memory state:

```
Alloy / OTel Collector  ──────────────────────────────────────►  LGTM backend
  (adds X-Scope-OrgID: tenant-a)                                  stores data under /tenant-a/...
```

In single-tenant deployments, the convention is `X-Scope-OrgID: anonymous` (set by default if auth is disabled).

### Enabling multi-tenancy in Mimir

```yaml
# mimir-values.yaml — in the dojo/production Helm release
mimir:
  structuredConfig:
    multitenancy_enabled: true
    limits:
      # Global defaults applied to every tenant
      ingestion_rate: 10000              # samples/sec total
      ingestion_burst_size: 200000
      max_label_names_per_series: 30
      max_label_value_length: 2048
      max_global_series_per_user: 500000 # 500k active series per tenant
      max_global_series_per_metric: 50000

      # Per-tenant overrides go in a separate ConfigMap consumed by the runtime config
```

Per-tenant overrides (the `runtime-config` pattern):

```yaml
# mimir-runtime-config.yaml — hot-reloaded without restarting Mimir
overrides:
  "tenant-payments":
    ingestion_rate: 50000              # payments team gets 5x the default
    max_global_series_per_user: 2000000
  "tenant-experiments":
    max_global_series_per_user: 100000  # experimental workloads capped low
    ingestion_rate: 1000
```

Mount this ConfigMap and tell Mimir where it is:

```yaml
mimir:
  structuredConfig:
    runtime_config:
      file: /etc/mimir/runtime-config.yaml
      period: 30s   # check for changes every 30s
```

Hot reloading means you can adjust a noisy neighbor's limits without restarting a single pod — critical for an incident response.

### Loki multi-tenancy: the same pattern

```yaml
# loki-values.yaml
loki:
  auth_enabled: true     # false = single tenant, headers ignored
  limits_config:
    ingestion_rate_mb: 4             # per-tenant log ingest rate
    ingestion_burst_size_mb: 8
    max_label_names_per_series: 15
    max_streams_per_user: 10000
    max_global_streams_per_user: 100000

    # retention by tenant — requires object-store backend (not filesystem)
    retention_period: 744h           # 31 days default
```

Tenant-specific retention is set in the runtime config overrides as `retention_period` per org.

---

## Object Storage: S3, GCS, MinIO, and Lifecycle

All three backends (Loki, Tempo, Mimir) write blocks to object storage. The bucket layout and lifecycle policy are operational knobs you must understand before you start a production rollout.

### Bucket layout per backend

```
# Mimir
s3://mimir-blocks/
  <tenant>/
    <block-ulid>/data     # Parquet TSDB blocks (compacted)
    <block-ulid>/index
    <block-ulid>/chunks
  markers/                # compaction markers (deletion candidates)

# Loki
s3://loki-chunks/
  <tenant>/
    <period>/
      <chunk-identifier>  # compressed log chunks (gzip/snappy/zstd)

s3://loki-index/          # separate bucket — never mix index and chunks
  <tenant>/
    index_<period>/

# Tempo
s3://tempo-traces/
  <tenant>/
    <block-uuid>/
      meta.json
      data                # vParquet3 columnar spans
      bloom-*
```

**Never put index and chunk buckets in the same path.** Loki splits them intentionally so you can apply different lifecycle policies (index is smaller, cheaper, often pinned longer; chunks can expire sooner).

### S3 lifecycle policy for cost control

```json
{
  "Rules": [
    {
      "ID": "mimir-block-expiry",
      "Status": "Enabled",
      "Filter": { "Prefix": "" },
      "Expiration": {
        "Days": 35
      },
      "NoncurrentVersionExpiration": {
        "NoncurrentDays": 1
      }
    }
  ]
}
```

Set the lifecycle policy to `retention + 5 days` (buffer for the compactor to finish before S3 deletes the raw data). If your retention is 30 days, set lifecycle expiry to 35 days. If S3 deletes blocks before Mimir's compactor finishes, you will get incomplete query results with no error — just silently missing data.

### MinIO in the dojo

```yaml
# In the kind cluster setup — MinIO in dojo-lgtm namespace
# The kube-dojo bootstrap creates these buckets:
# mimir-blocks, loki-chunks, loki-index, loki-ruler, tempo-traces
minio:
  rootUser: minio
  rootPassword: minio123
  buckets:
    - name: mimir-blocks
      policy: none
      purge: false
    - name: loki-chunks
      policy: none
    - name: loki-index
      policy: none
    - name: tempo-traces
      policy: none
```

Check bucket health:

```bash
kubectl exec -n dojo-lgtm deploy/minio -- mc alias set local http://localhost:9000 minio minio123
kubectl exec -n dojo-lgtm deploy/minio -- mc ls local/mimir-blocks
kubectl exec -n dojo-lgtm deploy/minio -- mc du local/tempo-traces
```

---

## Retention and Compaction

Retention and compaction are inseparable — compaction is what makes retention accurate.

### Mimir compactor

The compactor runs as a separate Kubernetes Deployment. Its job:

1. **Level-0 → Level-1:** Merge the 2-hour blocks that ingesters flush into 24-hour blocks.
2. **Level-1 → Level-2:** Merge 24-hour blocks into longer-period blocks (for tenants with long retention).
3. **Delete markers:** Once a block's time range is past retention, write a `deletion-mark.json` and eventually delete the block from object storage.

Compactor sizing matters. A single-replica compactor is the norm in small clusters, but it processes tenants sequentially. In a cluster with 50 tenants and 14-day retention, the compactor may take hours to finish a full pass. If it falls behind, blocks accumulate:

```bash
# Check compactor health
kubectl logs -n dojo-lgtm deploy/mimir-compactor --tail=100 | grep -E "error|compaction|tenant"

# Check per-tenant block counts (object storage — using mc)
kubectl exec -n dojo-lgtm deploy/minio -- mc ls local/mimir-blocks/ | wc -l  # total block dirs

# Mimir exposes compactor lag as a metric:
# cortex_compactor_blocks_cleaned_total
# cortex_compactor_runs_completed_total
# cortex_compactor_runs_failed_total
```

If `cortex_compactor_runs_failed_total` is climbing, the compactor is in a crash loop. Common cause: not enough memory to compact a large tenant's blocks. Increase the compactor's `resources.limits.memory`.

### Loki compactor (TSDB)

Loki's compactor merges index files and enforces log retention. For the `boltdb-shipper` backend (older), it runs as a singleton with a lock. For `tsdb` (current), it scales better:

```yaml
loki:
  structuredConfig:
    compactor:
      compaction_interval: 10m
      retention_enabled: true
      retention_delete_delay: 2h     # mark then wait 2h before deleting
      retention_delete_worker_count: 150
      delete_request_store: s3
```

---

## SLOs on the Telemetry Pipeline Itself

The most overlooked operational question: **what is your SLO for the observability platform?**

Most teams have an implicit 100% accuracy SLO ("I can always trust my metrics") but a de-facto 95% SLO (because the compactor falls behind, ingesters restart during deploys, etc.). You need to make this explicit.

### Recommended SLOs for self-hosted LGTM

| Signal | SLO | Reason |
|--------|-----|--------|
| **Metrics freshness** | < 2 min lag from scrape to query | Alert on `prometheus_remote_storage_queue_is_sharded - 0 AND scrape_timestamp - sample_timestamp > 120s` |
| **Metric write success rate** | ≥ 99.9% of samples written | 0.1% drop = silent gaps in dashboards; acceptable for an internal observability platform |
| **Log ingest rate** | ≥ 99.5% of log lines ingested | Logs are high-volume; brief ingestion drops during restarts are acceptable |
| **Trace completeness** | ≥ 99% of traces retrievable by ID within 5 min of emission | Missing traces break post-incident root cause analysis |
| **Query p99 latency** | < 10s for 24h range queries | Anything slower makes on-call unusable |

### Recording rules for pipeline SLOs

```yaml
# In a PrometheusRule CRD in dojo-lgtm namespace
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: lgtm-pipeline-slos
  namespace: dojo-lgtm
spec:
  groups:
    - name: lgtm.slo
      interval: 60s
      rules:
        - record: job:cortex_distributor_received_samples:rate5m
          expr: sum(rate(cortex_distributor_received_samples_total[5m])) by (job)

        - record: job:cortex_distributor_discarded_samples:rate5m
          expr: sum(rate(cortex_distributor_discarded_samples_total[5m])) by (job)

        - alert: MimirIngestionDropping
          expr: |
            job:cortex_distributor_discarded_samples:rate5m
            /
            job:cortex_distributor_received_samples:rate5m > 0.001
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Mimir is discarding > 0.1% of samples — check tenant limits"

        - alert: LokiIngesterUnhealthy
          expr: |
            (
              sum(cortex_ring_members{state="UNHEALTHY", name="ingester"}) by (cluster)
              /
              sum(cortex_ring_members{name="ingester"}) by (cluster)
            ) > 0.1
          for: 2m
          labels:
            severity: critical
```

---

## Meta-Monitoring: The Observability of Your Observability

The classic question: if Mimir is down, who monitors Mimir? This is the **meta-monitoring problem**, and every serious LGTM deployment needs an answer.

### Option 1: Separate Prometheus scraping LGTM

Run a lightweight Prometheus (not Mimir) that scrapes all LGTM components' `/metrics` endpoints. This Prometheus is:
- Small, not multi-tenant, not long-retention
- Separate from the main LGTM stack — it survives LGTM being down
- The source for "is the stack healthy" alerts that page the platform team

```yaml
# prometheus-meta.yaml — a separate Prometheus Deployment in dojo-meta namespace
apiVersion: apps/v1
kind: Deployment
metadata:
  name: prometheus-meta
  namespace: dojo-meta
spec:
  replicas: 1
  selector:
    matchLabels:
      app: prometheus-meta
  template:
    metadata:
      labels:
        app: prometheus-meta
    spec:
      containers:
        - name: prometheus
          image: prom/prometheus:v2.54.1
          args:
            - "--config.file=/etc/prometheus/prometheus.yml"
            - "--storage.tsdb.retention.time=7d"
          volumeMounts:
            - name: config
              mountPath: /etc/prometheus
      volumes:
        - name: config
          configMap:
            name: prometheus-meta-config
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-meta-config
  namespace: dojo-meta
data:
  prometheus.yml: |
    global:
      scrape_interval: 30s
    scrape_configs:
      - job_name: mimir-components
        static_configs:
          - targets:
            - mimir-distributor.dojo-lgtm.svc.cluster.local:8080
            - mimir-ingester.dojo-lgtm.svc.cluster.local:8080
            - mimir-compactor.dojo-lgtm.svc.cluster.local:8080
            - mimir-querier.dojo-lgtm.svc.cluster.local:8080
      - job_name: loki-components
        static_configs:
          - targets:
            - loki-ingester.dojo-lgtm.svc.cluster.local:3100
            - loki-distributor.dojo-lgtm.svc.cluster.local:3100
      - job_name: tempo-components
        static_configs:
          - targets:
            - tempo-distributor.dojo-lgtm.svc.cluster.local:3200
            - tempo-ingester.dojo-lgtm.svc.cluster.local:3200
            - tempo-compactor.dojo-lgtm.svc.cluster.local:3200
      - job_name: alloy
        kubernetes_sd_configs:
          - role: pod
            namespaces:
              names: [dojo-lgtm]
        relabel_configs:
          - source_labels: [__meta_kubernetes_pod_label_app_kubernetes_io_name]
            regex: alloy
            action: keep
```

### Option 2: Grafana Cloud remote_write (the real Grafana-Labs answer)

Grafana Labs itself runs Grafana Cloud as the meta-monitor for its hosted LGTM customers. The pattern is to remote_write a small set of health metrics *from* the self-hosted Mimir *to* a separate Grafana Cloud workspace. This works because the cloud workspace is not co-located with the cluster that's failing.

```yaml
# In Mimir's config — remote-write LGTM health metrics to cloud for meta-monitoring
mimir:
  structuredConfig:
    ruler_remote_write_url: "https://prometheus-prod-24-prod-eu-west-2.grafana.net/api/prom/push"
    ruler_remote_write_headers:
      Authorization: "Basic ${GRAFANA_CLOUD_TOKEN}"
```

### Key meta-monitoring metrics to alert on

```
# Mimir health
cortex_ring_members{state="UNHEALTHY"}           # ingester ring membership
cortex_compactor_runs_failed_total               # compactor failures
cortex_ingester_wal_replay_duration_seconds      # high value = slow recovery after crash

# Loki health
loki_ingester_streams_created_total              # rate drop = ingestion stopped
loki_compactor_apply_retention_last_successful_run_timestamp_seconds  # stale = retention stuck

# Tempo health
tempo_distributor_spans_received_total           # rate drop = no traces arriving
tempo_ingester_traces_created_total              # rate drop = ingestion stopped
tempo_compactor_block_retention_marked_total     # compaction progress

# Alloy / collector health
otelcol_processor_dropped_spans_total            # data being dropped
otelcol_processor_dropped_log_records_total
otelcol_exporter_send_failed_requests_total      # backend write failures
```

---

## Cost and Scale Tradeoffs

This is where the Grafana Labs SRE spends real time. Every knob you turn has a cost implication.

### Metrics: the cardinality-cost curve

Active series in Mimir scale storage IOPS (ingesters keep active series in memory). The relationship is roughly:

```
cost ≈ active_series * 2 bytes/sample * samples_per_second
     + active_series * ~1 KB (in-memory index overhead per ingester)
```

The moment a label has unbounded values (user ID, request ID, trace ID — don't do this), active series explode. The Mimir `max_global_series_per_user` limit is your firewall.

To identify cardinality bombs before they page you:

```bash
# In Grafana Explore, using Mimir:
# Top 10 metrics by series count
topk(10, count by(__name__)({__name__=~".+"}))

# Or use Mimir's cardinality API directly:
curl -s -H "X-Scope-OrgID: tenant-payments" \
  "http://mimir-nginx.dojo-lgtm.svc.cluster.local/prometheus/api/v1/label/__name__/values" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d['data']), 'metric names')"
```

### Logs: ingest rate vs. compression vs. query performance

Loki's cost model is dominated by storage (object storage is cheap) and query compute (expensive at high volume). The three knobs:

| Knob | Effect on cost | Effect on query perf |
|------|----------------|---------------------|
| `chunk_encoding: snappy` | Larger chunks (less compression) | Faster CPU during query |
| `chunk_encoding: zstd` | Smaller chunks (better compression) | Slower CPU during query |
| `max_chunk_age: 1h` | Fewer, larger chunks | Better bloom filter hit rate |
| High cardinality log labels | More streams = more index entries | Slower label queries |

Log labels in Loki are the equivalent of metric labels in Prometheus. Every unique label combination is a *stream*. A stream with `pod_name` as a label creates a new stream for every pod restart (different UID). Use `pod_name` as a label only if you're prepared for the stream explosion.

### Traces: storage is the variable; queries are CPU

Tempo's cost is dominated by object storage size. Spans in vParquet3 compress to roughly:

```
average span size = 500 bytes uncompressed → ~150 bytes in vParquet3
10k spans/sec → 1.5 MB/sec → ~130 GB/day
at 14-day retention → 1.8 TB
```

The lever is sampling rate. Every 10% you drop from the tail sampler saves 10% on storage. A cost-aware Tempo configuration:

```yaml
compactor:
  compaction:
    block_retention: 336h         # 14 days
    compacted_block_retention: 1h # delete un-compacted blocks fast after compaction
```

---

## Debugging Production LGTM

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Object storage PUT errors in Mimir ingester logs | IAM/RBAC permissions missing on the bucket, or wrong endpoint | Verify `aws s3 ls s3://mimir-blocks` works from the pod's service account; check bucket policy |
| Mimir queries returning partial data for old time ranges | Compactor has not yet merged old blocks, or blocks were deleted by S3 lifecycle before compaction finished | Check `cortex_compactor_runs_completed_total`; widen lifecycle expiry to `retention + 10 days` |
| Loki query times out for any range > 12h | Loki querier hitting too many chunks; no index acceleration | Enable Bloom compaction filter (`bloom_build_client` in Loki 3.x) and narrow queries with label selectors |
| One tenant's queries are degrading all other tenants' queries (noisy neighbor) | Expensive fan-out query scanning all ingesters for one tenant | Set `query_shards` per-tenant in runtime config; enable `query_scheduler` with per-tenant queue depth limits |
| Ingester ring splits (Mimir ring unhealthy) | Network partition between ingesters, or an ingester stuck in `LEAVING` state | `kubectl exec -n dojo-lgtm deploy/mimir-querier -- curl -s http://mimir-ingester:8080/ring \| grep -i leaving` |
| Compactor pod CrashLoopBackOff | OOM during large-tenant block compaction | Increase compactor `resources.limits.memory`; enable per-tenant compaction splitting (`compactor_blocks_retention_duration` per tenant in runtime config) |
| Alloy drops data after LGTM upgrade | New version of Alloy/LGTM has changed an endpoint or API version | Check Alloy exporter error logs; `otelcol_exporter_send_failed_requests_total` rising |
| Grafana shows "No data" for a dashboard that worked yesterday | Metric name changed by a cardinality clean-up or relabeling | `kubectl exec` into mimir-querier and query directly via `curl`; compare metric names with `label_values` API |

### The compactor backlog incident: exact playbook

```bash
# 1. Check if compactor is stuck
kubectl get pod -n dojo-lgtm -l app.kubernetes.io/component=compactor
kubectl logs -n dojo-lgtm deploy/mimir-compactor --tail=200 | grep -E "error|panic|compaction"

# 2. Check per-tenant block counts in MinIO
kubectl exec -n dojo-lgtm deploy/minio -- mc ls --recursive local/mimir-blocks/ \
  | awk '{print $NF}' | cut -d/ -f1 | sort | uniq -c | sort -rn | head -10

# 3. Check compactor metrics via meta-Prometheus
# cortex_compactor_blocks_cleaned_total should be increasing
# cortex_compactor_group_compactions_total should be > 0

# 4. Force a compactor restart with more memory if stuck
kubectl set resources deploy/mimir-compactor -n dojo-lgtm \
  --limits=memory=4Gi --requests=memory=2Gi

# 5. Verify blocks are compacting post-restart
kubectl logs -n dojo-lgtm deploy/mimir-compactor -f | grep "compacted"
```

### Diagnosing a noisy-neighbor tenant

```bash
# In Grafana Explore using meta-Prometheus:
# Per-tenant ingestion rate
sum(rate(cortex_distributor_received_samples_total[5m])) by (user)

# Per-tenant query latency (in Mimir querier logs)
kubectl logs -n dojo-lgtm deploy/mimir-querier --tail=500 \
  | grep -E '"user":"(tenant-payments|tenant-experiments)"' \
  | grep -i "duration\|slow\|timeout"

# If one tenant is clearly dominant, apply runtime limit immediately:
# Edit the runtime-config ConfigMap and set ingestion_rate and max_global_series_per_user
kubectl edit cm -n dojo-lgtm mimir-runtime-config
# Mimir picks up the change within 30s (runtime_config.period)
```

> **War story.** A fintech running self-hosted Mimir for their platform team saw query latencies degrade from 1s to 30s over three days with no code changes. The meta-Prometheus dashboard was the first signal: `cortex_ingester_memory_series` was growing 15% per day for one tenant. Investigation with the cardinality API revealed a recently deployed service emitting metrics with a `request_id` label — 2 million unique values per hour. The team had `max_global_series_per_user: 1000000` but the metric kept growing because the tenant was split across shards and the per-shard limit wasn't being hit. The fix was to set the *global* series limit in the runtime config override for that tenant and force-reload it. But the real lesson was the lack of a cardinality pre-flight check in the team's deploy pipeline. They added a step that runs `topk(1, count by(__name__, job)({...}))` against a staging Mimir before promoting any service. Silent cardinality growth is the slowest-burning observability fire there is.

---

## The Observability-of-Observability Problem

The recursive challenge: your observability platform needs to be observable, but if you use the same platform to observe itself, a failure state may consume its own diagnostic data. The principled resolution:

1. **Separate scrape tier.** The meta-Prometheus (or cloud workspace) described above is not optional. It's your circuit breaker.
2. **Alert on absence.** `absent(cortex_ring_members{state="ACTIVE"})` fires if Mimir is down entirely. Alertmanager routes this to a *separate* notification path (PagerDuty / OpsGenie directly, not through Grafana, because Grafana may also be down).
3. **K8s-native fallback.** If everything is down, `kubectl top pods -n dojo-lgtm` and `kubectl describe pod` still work. The debugging section of each module in this course used only `kubectl` for a reason.
4. **Runbooks.** The observability platform runbook cannot depend on the observability platform. Host it in a static page or a shared doc with no authentication dependency on the cluster.

---

## Checkpoint

You're ready for the operating-LGTM challenges when you can, without looking anything up:

1. Explain the `X-Scope-OrgID` header's role and what happens if it's absent in a multi-tenant Mimir deployment.
2. State the formula for S3 lifecycle expiry relative to retention, and what happens if the lifecycle fires before the compactor finishes.
3. Describe the difference between `limit_mib` in the OTel Collector and `max_global_series_per_user` in Mimir — what does each protect against?
4. Name three Mimir metrics that should be scraped by meta-Prometheus, and explain what each signals.
5. Explain why a `request_id` label on a metric is dangerous and how to detect it before it hits production.
6. Describe the noisy-neighbor scenario and name the Mimir runtime-config knob to apply an emergency cap.
7. Explain the observability-of-observability problem and describe one concrete mechanism to resolve the circular dependency.
8. Draw the meta-monitoring architecture (3 components) that survives the primary LGTM stack being fully down, and explain why each component is necessary.

This course has covered the full LGTM operational arc: log ingest and LogQL (Loki), metrics at scale (Mimir), distributed tracing (Tempo), the collection pipeline (Alloy/OTel), and production operations. The challenges that follow ask you to operate under failure conditions — each one is a scenario from a real production incident.
