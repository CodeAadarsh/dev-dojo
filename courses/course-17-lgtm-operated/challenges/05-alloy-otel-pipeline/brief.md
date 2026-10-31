# Alloy — Wire the OTel Pipeline

Traces and logs are being emitted by your pods, but nothing is picking them up. The plan: deploy Grafana Alloy as the telemetry agent and configure it with an end-to-end pipeline — receive OTLP over gRPC, apply back-pressure controls, and export to a backend. This is the pattern every large Grafana deployment runs; get it wrong and you saturate the collector under load.

## Mission

Deploy **Grafana Alloy** (from the `grafana/alloy` Helm chart) **or** an **OpenTelemetry Collector** into namespace `dojo-lgtm`.
Configure it with a pipeline that has all three stages:

| Stage | Examples |
|-------|---------|
| Receiver | `otelcol.receiver.otlp` (Alloy), or `receivers: otlp:` (OTel YAML) |
| Processor | `otelcol.processor.batch` or `otelcol.processor.memory_limiter` (Alloy), or `processors: batch:/memory_limiter:` (OTel YAML) |
| Exporter | `otelcol.exporter.otlp` → Tempo, or `otelcol.exporter.loki` → Loki, or `otelcol.exporter.prometheus` → Mimir (Alloy), or the OTel YAML equivalents |

The pipeline configuration must live in a **ConfigMap** in `dojo-lgtm` (both Helm charts create one automatically from your values).

## Target state — what `verify.sh` checks

1. **At least one Alloy or OTel Collector pod is Ready** in `dojo-lgtm` (selector: `app.kubernetes.io/name=alloy` or `app.kubernetes.io/name=opentelemetry-collector`).
2. **A ConfigMap belonging to that workload** (label `app.kubernetes.io/name=alloy` or `app.kubernetes.io/name=opentelemetry-collector`) contains **all three** of the words `receiver`, `processor`, and `exporter` (case-insensitive) in its data — confirming a real pipeline, not an empty config.

Run `bash courses/course-17-lgtm-operated/challenges/05-alloy-otel-pipeline/verify.sh` to check your work.

## Alloy River pipeline — the key concepts

Alloy's config language ("River") is functional: components declare inputs and outputs and you wire them together explicitly. This means a misconfigured pipeline fails at startup (not silently), and the dependency graph is inspectable.

```alloy
// 1. Receiver — accept OTLP traces/metrics/logs over gRPC and HTTP
otelcol.receiver.otlp "default" {
  grpc { endpoint = "0.0.0.0:4317" }
  http { endpoint = "0.0.0.0:4318" }

  output {
    traces  = [otelcol.processor.batch.default.input]
    metrics = [otelcol.processor.batch.default.input]
    logs    = [otelcol.processor.batch.default.input]
  }
}

// 2. Processor — batch to reduce write amplification
otelcol.processor.batch "default" {
  output {
    traces  = [otelcol.exporter.otlp.tempo.input]
    metrics = [otelcol.exporter.otlp.tempo.input]
    logs    = [otelcol.exporter.otlp.tempo.input]
  }
}

// 3. Exporter — send to Tempo (adjust endpoint to your Tempo service)
otelcol.exporter.otlp "tempo" {
  client {
    endpoint = "tempo.dojo-lgtm.svc.cluster.local:4317"
    tls { insecure = true }
  }
}
```

## Prereq — add the Grafana Helm repo

```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
```

## Why the processor stage matters

Without a `batch` processor, every span is a separate write to the backend — at 10k spans/s that's 10k RPC calls/s. The batch processor buffers and flushes on timeout or size, turning 10k writes into ~10 writes. The `memory_limiter` processor adds back-pressure: when the process RSS exceeds a threshold it starts rejecting telemetry rather than OOM-crashing. Both are required in any production collector config — this challenge forces you to include them.
