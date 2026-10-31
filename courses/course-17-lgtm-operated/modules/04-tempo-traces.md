# Tempo: Distributed Tracing

> **Module 04 · Course 17** — Metrics tell you *what* broke. Logs tell you *what happened*. Traces tell you *why* — across every service, queue, and database that touched the request. Tempo is Grafana's horizontally-scalable trace store. This module covers how it ingests, stores, and lets you query traces, and how to pull it into the same cost/cardinality conversation you're already having with Mimir.

You already know what a trace *is*. Move fast on the diagram; slow down at TraceQL, the metrics-generator, and sampling — that's where competent users end and Grafana-SRE-level users begin.

---

## The Ingest Path: OTLP All the Way Down

Tempo accepts traces through two main paths, but **OTLP is the one you should standardise on**:

```
your service  ──OTLP/gRPC──►  Tempo distributor  ──►  ingester  ──►  object store
               (port 4317)                                           (S3/GCS/MinIO)
                                  │
               OTLP/HTTP ─────────┘
               (port 4318)
```

The distributor hashes the trace ID and routes spans belonging to the same trace to the same ingester — this is how spans from different services end up assembled into one trace tree without Tempo needing a central coordinator.

Tempo's Helm values (`tempo-distributed` chart) to enable OTLP:

```yaml
distributor:
  config:
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: "0.0.0.0:4317"
          http:
            endpoint: "0.0.0.0:4318"
```

Tempo also accepts Jaeger Thrift, Zipkin, and OpenCensus — but those are migration paths, not new builds. If you find yourself writing Jaeger clients in 2025, stop and write an OTLP exporter.

### The Trace Object in Tempo

Tempo stores the raw protobuf of every span and builds a **bloom filter + block index** to make trace-by-ID lookups sub-second. The actual layout in object storage per block:

```
<tenant>/
  <block-uuid>/
    meta.json          # time range, attributes, bloom filter config
    data               # protobuf-encoded span data (Parquet in vParquet3)
    bloom-0 ... bloom-N  # per-shard bloom filters for trace ID lookup
    index.bloom        # top-level filter
```

vParquet3 (Tempo ≥ 2.2) stores spans in columnar format, which is what makes TraceQL attribute queries fast — it can skip whole row-groups without decoding them.

---

## Trace Storage: Object Store First

Unlike Loki (which you can run with a local filesystem for single replicas), **Tempo is designed for object storage from the start**. You should never run it in production with a local disk backend.

MinIO on kind for the dojo:

```yaml
# In tempo's HelmRelease or values.yaml — in the dojo namespace dojo-lgtm
storage:
  trace:
    backend: s3
    s3:
      bucket: tempo-traces
      endpoint: minio.dojo-lgtm.svc.cluster.local:9000
      access_key: minio
      secret_key: minio123
      insecure: true          # no TLS on in-cluster MinIO

compactor:
  compaction:
    block_retention: 72h      # 3-day dojo retention; set to 336h (14d) for production
```

The **compactor** is a Tempo component that merges small blocks (written by ingesters when they flush) into larger ones, and deletes blocks past retention. A stalled compactor is a storage pressure incident — see the Debugging section.

---

## TraceQL: Not Your Grandmother's Tracing UI

TraceQL is Tempo's trace query language. It operates on the **trace** as the first-class entity (not spans), which is the key mental shift:

```
{ span-filter }  |  pipeline-stage
```

### Span filters

```
# All traces that hit the payments service with an error
{ .service.name = "payments" && status = error }

# Traces where any span took > 2s
{ duration > 2s }

# Traces where the checkout span called a specific database
{ span.db.name = "orders" && name = "checkout" }

# Combine: slow payment traces
{ .service.name = "payments" && duration > 500ms && status != ok }
```

Attribute names follow the OTel semantic conventions:
- Resource attributes: `.service.name`, `.k8s.pod.name`
- Span attributes: `span.http.url`, `span.db.system`
- Intrinsics: `status`, `duration`, `name`, `rootName`, `rootServiceName`

### Aggregation pipeline (TraceQL metrics — Tempo ≥ 2.3)

TraceQL metrics let you compute RED (Rate / Errors / Duration) signals *from traces* at query time:

```
# p99 latency per service, over traces in the last hour
{ status != error } | rate()
{ .service.name =~ "order.*" } | histogram_over_time(duration) by (.service.name)

# Error rate: fraction of errored spans per service
rate({ status = error }[5m]) / rate({ }[5m])
```

This is powerful but compute-heavy on the Tempo querier. For steady-state dashboards, use the **metrics-generator** instead (below).

---

## Metrics-Generator: Span Metrics and Service Graphs

The metrics-generator is an optional Tempo component that derives Prometheus metrics from the span stream as they arrive in the ingesters. Two sub-processors:

### 1. Span Metrics

Emits a histogram per `(service, span_name, status_code)` tuple:

```
traces_spanmetrics_latency_bucket{service="checkout", span_name="POST /order", status_code="STATUS_CODE_OK", le="0.5"}
traces_spanmetrics_latency_count{...}
traces_spanmetrics_calls_total{...}
```

Use these in Grafana as you would any RED metrics — no TraceQL needed, which means alerting on latency percentiles with Mimir/Prometheus rules works out of the box.

### 2. Service Graphs

Derives a graph of service-to-service calls (edges) by matching client spans and server spans with the same trace ID:

```
traces_service_graph_request_total{client="frontend", server="checkout"}
traces_service_graph_request_failed_total{...}
traces_service_graph_request_server_seconds_bucket{...}
```

Grafana's **Service Graph panel** (in Explore → Traces) draws this as a live topology from these metrics.

### Configuring the metrics-generator

```yaml
# In tempo-distributed values
metricsGenerator:
  enabled: true
  config:
    storage:
      path: /tmp/wal
      remote_write:
        - url: http://mimir-nginx.dojo-lgtm.svc.cluster.local/api/v1/push
          send_exemplars: true      # critical — see Exemplars section

    processor:
      span_metrics:
        dimensions:
          - service.version
          - k8s.pod.name
      service_graphs:
        dimensions:
          - service.version
```

> **Cardinality warning.** `dimensions` in `span_metrics` explodes the label set. Adding `k8s.pod.name` multiplies every metric by the number of pods. In a 50-service cluster with 3 replicas each, that is 150 extra label values per metric. Keep dimensions minimal; index the data in Tempo instead and use exemplars to jump to the trace.

---

## Exemplars: The Link Between Metrics and Traces

An exemplar is a sample attached to a histogram observation that carries a trace ID. It is the bridge between a metric spike and the trace that caused it.

Mimir/Prometheus stores exemplars if you set `enable_exemplars_storage: true`. Tempo's metrics-generator emits them with `send_exemplars: true`. In Grafana:

1. Open a latency panel (Mimir source).
2. Enable "Exemplars" toggle in the query editor.
3. Click a diamond on the histogram — Grafana jumps to Tempo with that trace ID.

This is the full observability loop: alert fires on a metric → drill into the histogram → click an exemplar → land on the exact trace → open the offending span → see the log line.

---

## Sampling: Head vs Tail

Sampling is where teams make career-defining mistakes. Get the mental model right:

| | Head sampling | Tail sampling |
|---|---|---|
| **Decision point** | At span creation (SDK-side), before the trace completes | After the full trace arrives at a collector |
| **Information available** | Only what's known at the first span (service name, URL) | The entire trace: duration, errors, all attributes |
| **Cost** | Zero additional infrastructure | Requires stateful storage of in-flight traces (memory or disk) |
| **Use case** | High-volume healthy traffic you genuinely don't need | Error traces, slow traces, interesting traces you *can't* pre-identify |

**For the LGTM stack:** Tempo itself is not a sampler — it stores whatever you send. Sampling decisions happen in **Grafana Alloy** or the **OTel Collector** (the pipeline), not in Tempo.

### Head sampling in the SDK

```python
from opentelemetry.sdk.trace.sampling import TraceIdRatioBased

# Keep 10% of traces, decided at the root span
sampler = TraceIdRatioBased(0.1)
```

Problem: you lose 90% of error traces too.

### Tail sampling in the OTel Collector / Alloy

Tail sampling holds spans in memory until the trace is "complete" (timeout), then applies policies:

```yaml
# OTel Collector: tail sampling processor
processors:
  tail_sampling:
    decision_wait: 30s          # hold spans for up to 30s waiting for trace completion
    num_traces: 50000           # max in-flight traces in memory
    policies:
      - name: errors-policy
        type: status_code
        status_code: { status_codes: [ERROR] }
      - name: slow-traces
        type: latency
        latency: { threshold_ms: 1000 }
      - name: probabilistic-baseline
        type: probabilistic
        probabilistic: { sampling_percentage: 5 }   # 5% of everything else
```

> **The tail sampling memory trap.** `num_traces: 50000` at an average of 200 spans per trace and ~1 KB per span is 10 GB in the collector process. A traffic spike doubles that. Set `num_traces` based on your actual span-per-trace average and your collector's memory limit — not the default. The OOM will happen on a Friday.

---

## Debugging Tempo

Most Tempo incidents fall into three buckets: broken trace context (spans are in Tempo but don't assemble into traces), missing spans (data never arrived), and metrics-generator cardinality blowups.

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Trace exists in Tempo but only shows root span; other services' spans missing | Trace context not propagated correctly between services (W3C `traceparent` header stripped by middleware/proxy) | Add `propagators: [tracecontext, baggage]` to the SDK; check if your load balancer strips `traceparent` |
| No traces visible; Grafana Explore returns empty | Spans never reached Tempo distributor — exporter misconfigured or network blocked | `kubectl logs -n dojo-lgtm deploy/alloy | grep -i "tempo\|grpc\|4317"`; verify endpoint and port |
| Tempo querier pod OOMKilled during a trace search | TraceQL attribute query scanning too many blocks; no block pruning for the time range | Narrow the time range; add resource attribute constraints; check compactor is running and blocks are being merged |
| `traces_spanmetrics_*` missing from Mimir | metrics-generator remote_write failing | Check `kubectl logs -n dojo-lgtm deploy/tempo-metrics-generator`; verify Mimir remote_write URL is reachable |
| Service graph shows stale/missing edges | Client and server spans for the same trace not arriving at the same metrics-generator instance (stateless deployment with > 1 replica) | metrics-generator needs consistent routing — either run 1 replica or use a load-balancing strategy that pins by trace ID |
| Span attributes missing from TraceQL results | Attributes not indexed; Tempo only indexes resource attributes and configured span attributes by default | Add to `storage.trace.search.enabled_attributes` in config or upgrade to vParquet3 which indexes all attributes |
| High cardinality alert on `traces_spanmetrics_latency_bucket` | Too many `dimensions` in span_metrics config | Remove high-cardinality dimensions; check span attribute values for unbounded keys (user IDs, request IDs) |

### Diagnosing a broken trace context — the exact commands

Tempo's **tempo-query** API lets you look up a trace by ID directly and see what it received:

```bash
# Port-forward the Tempo query-frontend
kubectl port-forward -n dojo-lgtm svc/tempo-query-frontend 3200:3200 &

# Fetch the raw trace protobuf (requires a real trace ID from a span you saw in Alloy logs)
TRACE_ID="<your-trace-id>"
curl -s "http://localhost:3200/api/traces/${TRACE_ID}" \
  | python3 -c "import sys,json; t=json.load(sys.stdin); [print(s['traceId'], s['operationName']) for b in t['data'] for s in b['spans']]"
```

If the trace only shows one service's spans, the other services' spans were either sampled out or never had the trace context:

```bash
# Check what the OTel SDK is actually exporting — enable debug exporter
# In Alloy config temporarily:
otelcol.exporter.debug "trace-debug" {
  verbosity = "detailed"
}
# Then watch for traceparent propagation in SDK logs
kubectl logs -n dojo-apps deploy/checkout --tail=50 | grep -i "traceparent\|trace_id"
```

> **War story.** A checkout service at a fintech was emitting traces fine — I could see them in Tempo — but the downstream payment processor's spans were always missing. Three hours of config review found nothing wrong. The issue was an Nginx sidecar configured with `proxy_pass_header off` that stripped all custom headers including `traceparent`. The fix was one line in the Nginx config. The lesson: trace context propagation fails *silently*; the spans exist, they just start a new trace. Any time you see a single-service trace for a request that clearly crossed service boundaries, look at headers before looking at the SDK.

---

## Checkpoint

You're ready for the traces challenges when you can, without looking anything up:

1. Explain why Tempo routes spans for the same trace to the same ingester, and what breaks if that routing fails.
2. Write a TraceQL query that finds all traces from the `payments` service where any span took longer than 1 second and the overall status was an error.
3. Describe the difference between `span.http.url` and `.service.name` in TraceQL and which attribute prefix each uses.
4. Explain the cardinality risk of adding `k8s.pod.name` to span_metrics dimensions in a 50-service cluster.
5. Draw the exemplar link: how does a single alert on a Mimir metric get you to the exact Tempo trace?
6. State one scenario where head sampling is actively dangerous and explain why tail sampling with a `latency` policy is better.
7. Diagnose a trace that shows only the root span: what are the two most likely causes and the first command you run?
8. Describe what the compactor does and what symptoms a stalled compactor produces.

➡ Next up: **Alloy & the OpenTelemetry Collector** — the pipeline that gets telemetry *to* Tempo (and Loki and Mimir).
