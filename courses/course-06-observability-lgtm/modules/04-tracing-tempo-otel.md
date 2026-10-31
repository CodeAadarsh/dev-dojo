# Tracing with Tempo & OpenTelemetry

> **Module 04 · Course 06** — Metrics tell you *what* broke. Logs tell you *what* was recorded. Traces tell you *where the time went* and *which service caused it*. This module wires up distributed tracing end-to-end: OTel SDK → Collector pipeline → Grafana Tempo. By the end you can jump from a Prometheus histogram spike directly into the offending trace.

You already run Prometheus + Loki. Traces are the third pillar. At SAP's LGTM pipeline (100 GB+/day), exemplars linking metrics to Tempo traces are what cut mean-time-to-cause from hours to minutes. This module builds that exact chain.

---

## Spans, traces, and the data model

A **trace** is a directed acyclic tree of **spans** that describes a single request end-to-end.

```
TraceID: 4bf92f3577b34da6a3ce929d0e0e4736

  frontend          [root span · 0–210ms]
  ├─ auth-service   [child span · 2–14ms]
  │   └─ db-read    [child span · 3–12ms]
  └─ catalog-service [child span · 14–210ms]
      ├─ db-read    [child span · 15–23ms]
      └─ external-api [child span · 30–208ms]  ← 178ms here is your latency culprit
```

Every span carries a fixed set of fields:

| Field | Description |
|-------|-------------|
| `traceId` | 128-bit hex, same for every span in one request |
| `spanId` | 64-bit hex, unique per span |
| `parentSpanId` | the span that started this one; absent on the root |
| `startTimeUnixNano` / `durationNano` | timing |
| `attributes` | key/value pairs: `service.name`, `http.method`, `db.system`, `http.status_code` |
| `status` | `OK` / `ERROR` + optional message |
| `events` | point-in-time annotations on the span (e.g. "cache miss") |

**Context propagation** is how the traceId travels across service boundaries. The W3C `traceparent` header is the standard:

```
traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
             ^  ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^  ^^^^^^^^^^^^^^^^  ^
         version     traceId (32 hex)             parentSpanId     sampled flag
```

When service A calls service B over HTTP, A's SDK injects `traceparent` into the outgoing headers. B's SDK extracts it and opens a child span with the correct parent. **If `traceparent` is absent, B starts a new disconnected trace** — which is the root cause behind "where did my spans go?" in 90% of misconfigured setups. For gRPC it travels in metadata; for Kafka it lives in a message header.

> **Baggage vs. traceparent.** `traceparent` only carries the trace context. `baggage` is a separate W3C header for passing business data (user-id, region) transparently through the call chain without modifying every service's API signature. Use it sparingly — baggage is added to every span's attributes, so high-cardinality values balloon your storage.

---

## The OpenTelemetry pipeline

OpenTelemetry has two moving parts you deploy:

1. **OTel SDK** — inside the application (or injected via the OTel Operator).
2. **OTel Collector** — a standalone process that receives, processes, and exports telemetry.

```
┌───────────────────────────────────────────────────────────────────┐
│  app pod                                                           │
│  ┌─────────────┐                                                   │
│  │  OTel SDK   │──── OTLP/gRPC :4317 ─────────────────────────┐  │
│  └─────────────┘                                                │  │
└────────────────────────────────────────────────────────────────┼──┘
                                                                  │
                     ┌────────────────────────────────────────────▼──┐
                     │  OTel Collector (DaemonSet or Deployment)      │
                     │                                                │
                     │  receivers:  otlp(grpc :4317, http :4318)     │
                     │  processors: memory_limiter → batch → resource │
                     │  exporters:  otlp/tempo                        │
                     └────────────────────────────────┬───────────────┘
                                                      │ OTLP/gRPC
                                                      ▼
                     ┌──────────────────────────────────────────────┐
                     │  Grafana Tempo (namespace: monitoring)        │
                     │  stores spans, indexes by traceId/service/tag │
                     └──────────────────────────────────────────────┘
```

### Collector config anatomy

Deploy the Collector as a ConfigMap. The `service.pipelines` section is the wiring; the top-level blocks are the definitions. **A processor defined at the top but missing from `service.pipelines` silently does nothing** — this is the #1 config gotcha.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-collector-config
  namespace: monitoring
data:
  config.yaml: |
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318

    processors:
      memory_limiter:          # must be FIRST — drops before OOM
        limit_mib: 400
        spike_limit_mib: 100
        check_interval: 5s
      batch:                   # buffers spans; reduces exporter calls
        send_batch_size: 512
        timeout: 5s
      resource:                # inject cluster-level attributes
        attributes:
          - action: insert
            key: k8s.cluster.name
            value: dojo

    exporters:
      otlp/tempo:
        endpoint: tempo.monitoring.svc.cluster.local:4317
        tls:
          insecure: true

    service:
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, batch, resource]   # order matters
          exporters: [otlp/tempo]
```

---

## Sampling

Tracing every request at 100% is unsustainable at scale. Two strategies:

| Strategy | Where decided | Keeps | Loses |
|----------|---------------|-------|-------|
| **Head (TraceIdRatioBased)** | SDK or Collector receiver | A deterministic fraction of traces | Error/slow tail — a 5% error rate still loses many error traces |
| **Tail sampling** | Collector `tail_sampling` processor | All errors + slow spans regardless of rate | Requires buffering full traces in Collector memory |

The production pattern: **10% head sampling** with `parentbased_traceidratio` (all child spans inherit the root's sampling decision) **plus** a tail-sampling policy that keeps errors and P99 latency traces at 100%.

```yaml
processors:
  tail_sampling:
    decision_wait: 30s          # hold spans for 30s before deciding
    num_traces: 50000           # max traces buffered in memory
    policies:
      - name: errors-always
        type: status_code
        status_code: {status_codes: [ERROR]}
      - name: slow-requests
        type: latency
        latency: {threshold_ms: 2000}
      - name: sample-rest
        type: probabilistic
        probabilistic: {sampling_percentage: 10}
```

Set `decision_wait` to at least your P99 trace duration — if the slowest traces take 25 seconds, a 15-second `decision_wait` will make tail sampling decisions before all child spans arrive and some will be dropped.

---

## Exemplars: linking metrics to traces

An **exemplar** is a single data point attached to a Prometheus counter or histogram that includes `{traceId="..."}`. This is the connection from a panel spike in Grafana directly to a representative trace in Tempo.

Your app emits exemplars if:
1. The OTel SDK records histograms (e.g. `http.server.duration`) — it adds `traceId` automatically.
2. Prometheus is started with `--enable-feature=exemplar-storage`.
3. Prometheus scrapes exemplars (the default scrape config does once `exemplar-storage` is enabled).

Enable the feature flag in kube-prometheus-stack:

```yaml
# values patch for helm upgrade
prometheusSpec:
  enableFeatures:
    - exemplar-storage
```

In Grafana, on any histogram panel, click the data point and "Query with exemplars" is offered. The exemplar row contains the traceId; Grafana calls Tempo to fetch that trace. This is the pivot you want in an SRE incident.

---

## Deploying Tempo in the dojo

The kube-prometheus-stack must be installed first (`labs/bootstrap/install-monitoring.sh`). Add Tempo:

```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

helm upgrade --install tempo grafana/tempo \
  -n monitoring \
  --set tempo.storage.trace.backend=local \
  --set tempo.storage.trace.local.path=/var/tempo/traces \
  --set tempo.server.http_listen_port=3100 \
  --set "tempo.distributor.receivers.otlp.protocols.grpc.endpoint=0.0.0.0:4317" \
  --wait --timeout 5m
```

Add Tempo as a datasource in Grafana's `values.yaml` or via the UI:

```yaml
# in grafana.additionalDataSources (helm values)
- name: Tempo
  type: tempo
  url: http://tempo.monitoring.svc.cluster.local:3100
  jsonData:
    tracesToLogsV2:
      datasourceUid: loki          # jump from a trace span to Loki logs
      filterByTraceID: true
    serviceMap:
      datasourceUid: prometheus    # show service graph from span metrics
    lokiSearch:
      datasourceUid: loki
```

Verify Tempo is ingesting spans:

```bash
kubectl -n monitoring port-forward svc/tempo 3100:3100 &
curl -s 'http://localhost:3100/api/search?limit=3'
# non-empty "traces" array = working
```

---

## Debugging Tracing

Tracing failures are almost always silent — no error is thrown, spans just disappear. Work the pipeline from left (app) to right (Tempo).

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| No traces in Tempo; app reports no export errors | OTLP endpoint unreachable from app pod | `kubectl exec` into app pod: `nc -zv otel-collector.monitoring 4317`; check `OTEL_EXPORTER_OTLP_ENDPOINT` |
| Traces present but spans from service B are missing | `traceparent` not propagated through B | Check B's HTTP client middleware for W3C header injection; some frameworks (Django, older Spring) strip unknown headers by default |
| Errors and slow traces are missing despite tail sampling | `tail_sampling` defined but not wired into `service.pipelines` | Verify the processor name appears in `service.pipelines.traces.processors` list |
| `otelcol_processor_dropped_spans` rising in Collector metrics | Queue full: exporter slow or Tempo backpressure | Raise `sending_queue.queue_size`; add `retry_on_failure`; check Tempo pod resource limits |
| Grafana Tempo "no results" for a valid traceId | Tempo search index lag (~5s) or wrong datasource port | Wait 10s and retry; datasource URL must be HTTP port 3100, not gRPC port 4317 |
| Auto-instrumentation pod stuck in `Init:0/1` | OTel Operator not installed or `Instrumentation` CR missing | `kubectl get instrumentation -A`; confirm Operator is running in `opentelemetry-operator-system` |

### Exact diagnostic commands

Check whether the Collector is receiving and dropping spans:

```bash
kubectl -n monitoring logs -l app.kubernetes.io/name=opentelemetry-collector \
  --tail=100 | grep -E 'drop|error|refused|failed'
```

Check Collector's self-reported metrics (it exposes Prometheus metrics on port 8888):

```bash
kubectl -n monitoring port-forward \
  $(kubectl -n monitoring get pod -l app.kubernetes.io/name=opentelemetry-collector \
    -o jsonpath='{.items[0].metadata.name}') 8888:8888 &
curl -s http://localhost:8888/metrics | \
  grep -E 'otelcol_processor_dropped|otelcol_exporter_send_failed|otelcol_receiver_accepted'
```

Verify a specific traceId exists in Tempo:

```bash
TRACE_ID="4bf92f3577b34da6a3ce929d0e0e4736"
kubectl -n monitoring port-forward svc/tempo 3100:3100 &
curl -s "http://localhost:3100/api/traces/${TRACE_ID}" | \
  python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('batches',[])), 'batches')"
```

Check whether `traceparent` is being injected into outgoing HTTP calls from a service:

```bash
kubectl -n dojo-tracing exec -it deploy/frontend -- sh -c \
  'wget -S http://auth-service:8080/health 2>&1 | grep -i traceparent'
```

> **War story.** The LGTM pipeline at SAP showed a ghost forest: Loki had 100% of logs, Prometheus had 100% of metrics, but Tempo had traces for only 3% of requests despite the SDK reporting `export success`. The Collector ConfigMap had the `tail_sampling` processor block defined at the top level — but the processor name was not in the `service.pipelines.traces.processors` array. It was declared and completely ignored. Every span was flushed at the 10% head-sampling rate. The fix was a two-line edit. The lesson: the OTel Collector config validates each section in isolation; it does not cross-check that declared processors are actually wired into a pipeline. If a processor is missing from the pipeline list, it is silently a no-op.

---

## Checkpoint

You are ready for the challenges when you can, without looking anything up:

1. Draw a 4-service trace tree and label traceId, spanId, parentSpanId, and the W3C `traceparent` header value for one hop.
2. Explain why a missing `traceparent` header produces two disconnected traces rather than an error.
3. Recite the correct processor order in an OTel Collector traces pipeline and explain why `memory_limiter` must be first.
4. State the difference between head sampling and tail sampling; give the scenario where each is appropriate.
5. Explain what an exemplar is, which Prometheus flag enables it, and how Grafana uses it to jump to a trace.
6. Query Tempo's HTTP API from the command line to check whether a given traceId was ingested.
7. Diagnose `otelcol_processor_dropped_spans` rising using the Collector's self-metrics endpoint.
8. Reproduce the war-story bug in one sentence and state the two-line fix.

→ Next up: **Grafana & Correlating Signals** — building the dashboard that connects metrics, logs, and traces in a single pane.
