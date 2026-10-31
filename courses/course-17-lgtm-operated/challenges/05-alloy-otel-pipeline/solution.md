# Solution: Alloy — Wire the OTel Pipeline

## Option A — Grafana Alloy (River syntax)

### 1. Create an Alloy values file

```yaml
# alloy-values.yaml
alloy:
  configMap:
    content: |
      // ── Receiver: accept OTLP traces, metrics, and logs ──────────────────
      otelcol.receiver.otlp "default" {
        grpc { endpoint = "0.0.0.0:4317" }
        http { endpoint = "0.0.0.0:4318" }

        output {
          traces  = [otelcol.processor.memory_limiter.default.input]
          metrics = [otelcol.processor.memory_limiter.default.input]
          logs    = [otelcol.processor.memory_limiter.default.input]
        }
      }

      // ── Processor: back-pressure gate ─────────────────────────────────────
      otelcol.processor.memory_limiter "default" {
        check_interval         = "1s"
        limit_mib              = 256
        spike_limit_mib        = 64

        output {
          traces  = [otelcol.processor.batch.default.input]
          metrics = [otelcol.processor.batch.default.input]
          logs    = [otelcol.processor.batch.default.input]
        }
      }

      // ── Processor: batch to reduce write amplification ────────────────────
      otelcol.processor.batch "default" {
        output {
          traces  = [otelcol.exporter.otlp.tempo.input]
          metrics = [otelcol.exporter.otlp.tempo.input]
          logs    = [otelcol.exporter.otlp.tempo.input]
        }
      }

      // ── Exporter: send traces to Tempo (adjust if Tempo not installed) ────
      otelcol.exporter.otlp "tempo" {
        client {
          endpoint = "tempo.dojo-lgtm.svc.cluster.local:4317"
          tls { insecure = true }
        }
      }

  resources:
    requests:
      cpu: 50m
      memory: 128Mi
    limits:
      cpu: 200m
      memory: 256Mi
```

### 2. Install

```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
helm install alloy grafana/alloy -n dojo-lgtm -f alloy-values.yaml
```

### 3. Confirm the pipeline is wired

```bash
kubectl -n dojo-lgtm get pods -l app.kubernetes.io/name=alloy
kubectl -n dojo-lgtm logs -l app.kubernetes.io/name=alloy | grep -E 'receiver|processor|exporter|error'
```

Alloy also exposes a diagnostic UI on port 12345 of the pod:

```bash
kubectl -n dojo-lgtm port-forward svc/alloy 12345:12345 &
# open http://localhost:12345/graph — shows the live component graph
```

---

## Option B — OpenTelemetry Collector (YAML format)

### 1. Create a collector values file

```yaml
# otelcol-values.yaml
config:
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: 0.0.0.0:4317
        http:
          endpoint: 0.0.0.0:4318

  processors:
    memory_limiter:
      check_interval: 1s
      limit_mib: 256
      spike_limit_mib: 64
    batch:
      timeout: 5s
      send_batch_size: 512

  exporters:
    otlp/tempo:
      endpoint: "tempo.dojo-lgtm.svc.cluster.local:4317"
      tls:
        insecure: true

  service:
    pipelines:
      traces:
        receivers:  [otlp]
        processors: [memory_limiter, batch]
        exporters:  [otlp/tempo]
      metrics:
        receivers:  [otlp]
        processors: [memory_limiter, batch]
        exporters:  [otlp/tempo]
      logs:
        receivers:  [otlp]
        processors: [memory_limiter, batch]
        exporters:  [otlp/tempo]
```

```bash
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update
helm install opentelemetry-collector open-telemetry/opentelemetry-collector \
  -n dojo-lgtm \
  -f otelcol-values.yaml
```

---

## Run the verifier

```bash
bash courses/course-17-lgtm-operated/challenges/05-alloy-otel-pipeline/verify.sh
```

## Why memory_limiter before batch

Order matters. If `batch` comes first, it can accumulate many spans in memory before the `memory_limiter` gets a chance to reject. By placing `memory_limiter` before `batch`, the gate fires on raw ingest rate and the batch processor only sees data the process can actually afford — preventing OOM crashes under bursty load. This is the canonical order in Grafana's production Alloy configs and OTel Collector documentation.

## Hardening preview

- Pin Alloy's image: `alloy.image.tag: "v1.4.3"` in values — never `:latest` in a collector you depend on for SLOs.
- Add `otelcol.processor.attributes "default"` to strip high-cardinality labels (user IDs, request GUIDs) before they reach Tempo — cardinality is the top cause of Tempo storage blowup.
- Configure `otelcol.exporter.otlp` with `retry_on_failure` and `sending_queue` to survive downstream restarts without losing spans.
