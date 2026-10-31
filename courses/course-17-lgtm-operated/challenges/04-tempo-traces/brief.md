# Tempo — Ship the Trace Receiver

Your team's microservices already export OTLP traces; the problem is there's nowhere to send them. The on-call engineer provisioned Grafana last sprint but never added a trace backend — every `otelcol.exporter.otlp` points at `localhost:4317` and silently drops. You have 30 minutes before the next deploy.

## Mission

Install Grafana Tempo from the `grafana/tempo` Helm chart into namespace `dojo-lgtm`.
The Helm release **must be named `tempo`**.
The OTLP receiver must be enabled — the default Tempo config only enables Jaeger/Zipkin; you need to add the OTLP receiver explicitly so traces can be pushed over gRPC (port 4317) and HTTP (port 4318).

## Target state — what `verify.sh` checks

1. **Helm release `tempo` exists** in `dojo-lgtm` (`helm -n dojo-lgtm list -q | grep ^tempo$`).
2. **A Service in `dojo-lgtm` exposes port 4317 or 4318** — the OTLP ingress ports.
3. **At least one Tempo pod is Ready** — the process started and passed its health check.

Run `bash courses/course-17-lgtm-operated/challenges/04-tempo-traces/verify.sh` to check your work.

## Sending a test trace (bonus — do this after the verifier passes)

A quick way to confirm traces are landing: run a telemetrygen pod that sends OTLP spans directly to the service.

```bash
# find the Tempo service ClusterIP
kubectl -n dojo-lgtm get svc -l app.kubernetes.io/name=tempo

# fire 100 synthetic spans at the OTLP gRPC endpoint
kubectl run tracegen --rm -it --restart=Never \
  --image=ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:0.111.0 \
  -n dojo-lgtm \
  -- traces --otlp-insecure \
     --otlp-endpoint=tempo.dojo-lgtm.svc.cluster.local:4317 \
     --duration=5s
```

## Querying traces with TraceQL

Once Grafana is installed and datasourced to Tempo, open Explore and try:

```
{ .service.name = "telemetrygen" }
```

Or from `kubectl` via the HTTP API:

```bash
# port-forward Tempo's HTTP API
kubectl -n dojo-lgtm port-forward svc/tempo 3200:3200 &

# list services that sent traces in the last 5 min
curl -s 'http://localhost:3200/api/search/tags?scope=resource' | grep -o '"service.name"'

# TraceQL search — traces with status=error in the last hour
curl -s --get 'http://localhost:3200/api/search' \
  --data-urlencode 'q={ status = error }' \
  --data-urlencode 'limit=5' | grep -o '"traceID":"[^"]*"'
```

## Why it matters

Distributed tracing without a receiver is observability theater. The OTLP protocol (OpenTelemetry Protocol) is the lingua franca of modern telemetry — once you have an OTLP-capable backend you can swap Tempo for Jaeger, Zipkin, or an OTLP-native SaaS without touching your instrumentation. The receiver config is the integration point every SRE and platform engineer owns.

## Prereq — add the Grafana Helm repo

```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
```
