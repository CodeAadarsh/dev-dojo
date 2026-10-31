# Alloy & the OpenTelemetry Collector

> **Module 05 · Course 17** — Every signal your app emits has to travel somewhere. Whether you call it the "agent layer," the "collector tier," or the "pipeline," this is the component that receives, transforms, and routes telemetry. You have two serious options in the LGTM ecosystem: **Grafana Alloy** (the successor to the Agent, Promtail, and the old Grafana Agent Flow) and the **OpenTelemetry Collector**. This module covers both, explains when to use which, and digs into the operational failure modes that will cost you data in production.

You're operating at the intersection of the app and the observability platform. Every misconfiguration here silently drops data, not loudly fails.

---

## Alloy vs the OTel Collector: Pick One and Be Consistent

The honest comparison:

| | Grafana Alloy | OTel Collector |
|---|---|---|
| **Language** | River (Alloy's own HCL-like DSL) | YAML |
| **Ecosystem fit** | Native LGTM: Loki, Tempo, Mimir, Pyroscope — tight integration with Grafana's service discovery and dashboards | Vendor-neutral: works with any backend, part of CNCF |
| **Collector contrib** | Includes all OTel Collector contrib receivers/processors (Alloy wraps the OTel core) | The upstream reference implementation |
| **Service discovery** | Built-in Kubernetes pod/service discovery; scrape configs look like Prometheus | Prometheus receiver for metrics; K8s attribute processor for enrichment |
| **Profile support** | Pyroscope (continuous profiling) built-in | No first-class profiling; pprof receiver is basic |
| **When to choose** | You are running the full Grafana stack and want one agent config for all 4 signals | You are in a multi-vendor environment, contributing to OSS tooling, or your platform team mandates OTel Collector |

**The Grafana-Labs SRE answer:** use Alloy if your whole stack is LGTM; use OTel Collector if you also need to fan out to Datadog, New Relic, or another vendor simultaneously. The `lgtm-distributed` Helm chart defaults to Alloy.

> **They are not exclusive.** A common pattern is running an OTel Collector *sidecar* next to the app (SDK exporter → sidecar collector → Alloy DaemonSet → LGTM backends). The sidecar handles batching and local retries; Alloy handles routing and service discovery.

---

## The Pipeline Mental Model: Receivers → Processors → Exporters

Both Alloy and the OTel Collector are fundamentally a pipeline. Understanding this model is the prerequisite for diagnosing *every* data-loss incident.

```
┌──────────────┐     ┌──────────────────────────────────┐     ┌──────────────┐
│  Receivers   │────►│           Processors              │────►│  Exporters   │
│              │     │  (transform, filter, batch, drop) │     │              │
│ OTLP/gRPC    │     │  memory_limiter  (first)          │     │  OTLP → Tempo│
│ OTLP/HTTP    │     │  k8sattributes                    │     │  OTLP → Loki │
│ Prometheus   │     │  resource                         │     │  remote_write│
│ Filelog      │     │  batch          (last)            │     │  → Mimir     │
│ Kubeletstats │     │                                   │     │              │
└──────────────┘     └──────────────────────────────────┘     └──────────────┘
```

**Order matters for processors.** The canonical order is:
1. `memory_limiter` — must be first, before any data is materialized
2. Enrichment processors (`k8sattributes`, `resource`, `attributes`)
3. Filtering/sampling processors
4. `batch` — must be last, so it batches already-enriched data

Getting this order wrong is a common cause of dropped data and incorrect enrichment — see the Debugging section.

---

## OTel Collector Pipeline Config (YAML)

```yaml
# otelcol-config.yaml — deploy as a ConfigMap in dojo-lgtm
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: "0.0.0.0:4317"
      http:
        endpoint: "0.0.0.0:4318"
  prometheus:
    config:
      scrape_configs:
        - job_name: "kube-pods"
          kubernetes_sd_configs:
            - role: pod
          relabel_configs:
            - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
              action: keep
              regex: "true"
  filelog:
    include: ["/var/log/pods/*/*/*.log"]
    start_at: beginning
    operators:
      - type: json_parser
        timestamp:
          parse_from: attributes.time
          layout: "%Y-%m-%dT%H:%M:%S.%LZ"

processors:
  memory_limiter:
    check_interval: 1s
    limit_mib: 400          # 80% of the container's memory limit
    spike_limit_mib: 100

  k8sattributes:
    auth_type: serviceAccount
    passthrough: false
    extract:
      metadata:
        - k8s.namespace.name
        - k8s.pod.name
        - k8s.pod.uid
        - k8s.node.name
        - k8s.deployment.name
      labels:
        - tag_name: app
          key: app.kubernetes.io/name
          from: pod

  resource:
    attributes:
      - action: upsert
        key: cluster
        value: "dojo"

  batch:
    send_batch_size: 512
    timeout: 5s
    send_batch_max_size: 1024

exporters:
  otlphttp/tempo:
    endpoint: "http://tempo-distributor.dojo-lgtm.svc.cluster.local:4318"
    tls:
      insecure: true

  loki:
    endpoint: "http://loki-gateway.dojo-lgtm.svc.cluster.local/loki/api/v1/push"
    default_labels_enabled:
      exporter: false
      job: true

  prometheusremotewrite/mimir:
    endpoint: "http://mimir-nginx.dojo-lgtm.svc.cluster.local/api/v1/push"
    tls:
      insecure: true

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, k8sattributes, resource, batch]
      exporters: [otlphttp/tempo]
    logs:
      receivers: [filelog]
      processors: [memory_limiter, k8sattributes, resource, batch]
      exporters: [loki]
    metrics:
      receivers: [otlp, prometheus]
      processors: [memory_limiter, k8sattributes, resource, batch]
      exporters: [prometheusremotewrite/mimir]
```

### The RBAC requirement for k8sattributes

The `k8sattributes` processor calls the Kubernetes API to look up pod metadata by IP. The collector's ServiceAccount needs these permissions:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: otelcol-k8s-metadata
rules:
  - apiGroups: [""]
    resources: ["pods", "namespaces", "nodes"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["replicasets"]
    verbs: ["get", "list", "watch"]
```

Missing this ClusterRole causes `k8sattributes` to log `permission denied` and fall through — spans arrive in Tempo without namespace/pod labels, making them nearly unsearchable.

---

## Grafana Alloy Pipeline Config (River)

Alloy uses the River configuration language. The same pipeline as above looks like:

```river
// alloy/config.alloy — deployed in dojo-lgtm

// ── Receivers ───────────────────────────────────────────────────────────────

otelcol.receiver.otlp "default" {
  grpc { endpoint = "0.0.0.0:4317" }
  http { endpoint = "0.0.0.0:4318" }

  output {
    traces  = [otelcol.processor.memory_limiter.default.input]
    metrics = [otelcol.processor.memory_limiter.default.input]
    logs    = [otelcol.processor.memory_limiter.default.input]
  }
}

// ── Processors ──────────────────────────────────────────────────────────────

otelcol.processor.memory_limiter "default" {
  check_interval   = "1s"
  limit_mib        = 400
  spike_limit_mib  = 100

  output {
    traces  = [otelcol.processor.k8sattributes.default.input]
    metrics = [otelcol.processor.k8sattributes.default.input]
    logs    = [otelcol.processor.k8sattributes.default.input]
  }
}

otelcol.processor.k8sattributes "default" {
  auth_type = "serviceAccount"

  extract {
    metadata = ["k8s.namespace.name", "k8s.pod.name", "k8s.deployment.name", "k8s.node.name"]
  }

  output {
    traces  = [otelcol.processor.batch.default.input]
    metrics = [otelcol.processor.batch.default.input]
    logs    = [otelcol.processor.batch.default.input]
  }
}

otelcol.processor.batch "default" {
  send_batch_size     = 512
  timeout             = "5s"
  send_batch_max_size = 1024

  output {
    traces  = [otelcol.exporter.otlphttp.tempo.input]
    metrics = [otelcol.exporter.prometheusremotewrite.mimir.input]
    logs    = [otelcol.exporter.loki.default.input]
  }
}

// ── Exporters ───────────────────────────────────────────────────────────────

otelcol.exporter.otlphttp "tempo" {
  client {
    endpoint = "http://tempo-distributor.dojo-lgtm.svc.cluster.local:4318"
    tls { insecure = true }
  }
}

otelcol.exporter.prometheusremotewrite "mimir" {
  endpoint = "http://mimir-nginx.dojo-lgtm.svc.cluster.local/api/v1/push"
}

otelcol.exporter.loki "default" {
  forward_to = [loki.write.default.receiver]
}

loki.write "default" {
  endpoint {
    url = "http://loki-gateway.dojo-lgtm.svc.cluster.local/loki/api/v1/push"
  }
}

// ── Prometheus scrape (Alloy native) ────────────────────────────────────────

prometheus.scrape "pods" {
  targets    = prometheus.operator.podmonitors.pods.targets
  forward_to = [otelcol.receiver.prometheus.default.receiver]
}

otelcol.receiver.prometheus "default" {
  output {
    metrics = [otelcol.processor.memory_limiter.default.input]
  }
}
```

Alloy's directed-graph model (each component wires its `output` to another component's `input`) makes pipeline topology explicit and refactorable. Unlike YAML, a bad reference is a parse error at startup, not a silent miss at runtime.

---

## Batching and the Memory Limiter: The Two Non-Negotiables

These two processors prevent the two most common data-loss incidents in collector operations.

### memory_limiter — prevents OOM kills

The memory_limiter watches the process RSS and starts refusing new data when it approaches `limit_mib`. When `spike_limit_mib` is breached by a sudden inflow, it drops data *instead of crashing* — which is the right trade-off.

```
Memory usage
    |
    |  spike_limit_mib ──► drop new data (GRPC returns ResourceExhausted)
    |  limit_mib       ──► refuse new data
    |  normal          ──► pass through
    |
    └────────────────────────────────────────────────── time
```

Set `limit_mib` to 80% of the container's `resources.limits.memory`. Set `spike_limit_mib` to 25% of `limit_mib`. If you set `limit_mib` equal to the container limit, the OOM killer will race with the memory_limiter and occasionally win.

### batch — reduces backend write amplification

Without batching, every span triggers a separate HTTP/gRPC write to Tempo. At 10k spans/second that is 10k tiny writes. With `batch` (send_batch_size=512, timeout=5s), you get either 512-span batches or a flush every 5 seconds — whichever comes first. The backends (Loki, Tempo, Mimir) are all optimised for bulk writes, not per-item writes.

`send_batch_max_size` caps the maximum batch to prevent an unexpected burst from producing a request that exceeds the backend's payload limit (Tempo defaults to 4MB per request).

---

## Service Discovery in Kubernetes

### OTel Collector with `k8s_observer` + `receiver_creator`

The receiver_creator pattern lets the collector dynamically spin up receivers for newly discovered pods:

```yaml
extensions:
  k8s_observer:
    auth_type: serviceAccount
    observe_nodes: true
    observe_pods: true

receivers:
  receiver_creator:
    watch_observers: [k8s_observer]
    receivers:
      prometheus_simple:
        rule: type == "pod" && annotations["prometheus.io/scrape"] == "true"
        config:
          endpoint: '`endpoint`:`annotations["prometheus.io/port"]`'
          collection_interval: 30s
          metrics_path: '`annotations["prometheus.io/path"]`'
```

### Alloy native Kubernetes discovery

Alloy's `prometheus.operator.podmonitors` and `discovery.kubernetes` components are idiomatic:

```river
discovery.kubernetes "pods" {
  role = "pod"
  namespaces { names = ["dojo-apps"] }
}

discovery.relabel "pods" {
  targets = discovery.kubernetes.pods.targets

  rule {
    source_labels = ["__meta_kubernetes_pod_annotation_prometheus_io_scrape"]
    action        = "keep"
    regex         = "true"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_annotation_prometheus_io_port"]
    target_label  = "__address__"
    replacement   = "$1:$2"  // pod IP from __address__, port from annotation
  }
}

prometheus.scrape "pods" {
  targets    = discovery.relabel.pods.output
  forward_to = [prometheus.remote_write.mimir.receiver]
}
```

---

## The Collector as the Single Telemetry Hub

The architecture decision worth internalising: **put the collector between every app and every backend**. Never let apps write directly to Loki/Tempo/Mimir from production workloads.

```
app pod ──OTLP──► Alloy DaemonSet ──►  Tempo   (traces)
                                   ──►  Loki    (logs)
                                   ──►  Mimir   (metrics)
                                   ──►  Pyroscope (profiles)
```

Benefits:
- **Retry buffering.** If Tempo is down for 2 minutes, the collector queues spans and replays. Apps using direct OTLP exporters drop those 2 minutes.
- **Enrichment once.** k8sattributes runs once in the collector, not in every app's SDK.
- **Traffic shaping.** Rate limiting, sampling, and filtering live in the collector config, not scattered across 40 services.
- **Backend migration.** Switch from Tempo to Jaeger by changing one exporter line, not redeploying 40 apps.

---

## TLS and OTLP Endpoint Errors

In-cluster LGTM usually runs with `insecure: true` because services communicate over the cluster network. But in multi-cluster, cross-DC, or Grafana Cloud setups, you need mTLS.

OTLP gRPC with TLS:

```yaml
# OTel Collector exporter
exporters:
  otlp/tempo:
    endpoint: "tempo.prod.example.com:4317"
    tls:
      insecure: false
      cert_file: /etc/certs/client.crt
      key_file:  /etc/certs/client.key
      ca_file:   /etc/certs/ca.crt
```

OTLP HTTP with bearer token (Grafana Cloud):

```yaml
exporters:
  otlphttp/cloud:
    endpoint: "https://tempo-prod-06-prod-us-central-0.grafana.net/tempo"
    headers:
      authorization: "Basic ${GRAFANA_CLOUD_TOKEN}"
```

The `GRAFANA_CLOUD_TOKEN` should come from an environment variable sourced from a Kubernetes Secret, not hardcoded in the ConfigMap.

---

## Debugging the Collector

This is the section that matters at 3 AM. Silent data loss is the collector's failure mode.

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Spans arriving in app but not in Tempo; no errors in app logs | Collector can't reach Tempo OTLP endpoint — network policy or wrong port | `kubectl exec -n dojo-lgtm deploy/alloy -- wget -qO- http://tempo-distributor:4318/` should 404, not hang |
| `ResourceExhausted` gRPC errors in collector logs | `memory_limiter` is dropping data — collector is under memory pressure | Increase collector memory limit, or raise `limit_mib` (it's set too low); check for a processing bottleneck upstream |
| Logs arrive in Loki without `k8s.pod.name` label | `k8sattributes` processor is not enriching — RBAC missing or processor order wrong | Verify ClusterRoleBinding; check that `memory_limiter` is before `k8sattributes` in pipeline |
| Metrics disappear periodically (every 5–30 min) | Batch processor timeout causing large batches that exceed Mimir's payload limit | Lower `send_batch_max_size` or increase Mimir's `max_recv_msg_size` |
| `OTLP exporter ... connection refused` | Service name/port wrong, or Tempo distributor pod not running | `kubectl get svc -n dojo-lgtm | grep tempo`; `kubectl get pod -n dojo-lgtm -l app=tempo-distributor` |
| River config parse error on Alloy startup | Invalid component reference or wiring loop | `alloy fmt config.alloy` catches syntax errors; check component names match exactly between `output` and the target component |
| Traces missing after Alloy pod restart | Alloy in-memory WAL was not flushed — no persistence configured | Add `otelcol.exporter.otlphttp.tempo` with `sending_queue { storage = file_storage.queue }` for durable queue |

### Diagnosing dropped data — the exact commands

Enable the `zpages` extension to get a live view of pipeline state:

```yaml
extensions:
  zpages:
    endpoint: "0.0.0.0:55679"
```

Then port-forward and open the pipeline view:

```bash
kubectl port-forward -n dojo-lgtm deploy/otelcol 55679:55679 &
# Open in browser: http://localhost:55679/debug/tracez
# Or query directly:
curl -s http://localhost:55679/debug/pipelinez | grep -i "refused\|drop\|error"
```

The `pipelinez` page shows per-pipeline accepted/refused/dropped counts — the fastest way to confirm data is actually flowing.

For Alloy, the built-in UI on port 12345:

```bash
kubectl port-forward -n dojo-lgtm deploy/alloy 12345:12345 &
# http://localhost:12345 shows the pipeline graph, component health, and metrics
```

> **War story.** On a production LGTM migration at a fintech, we lost 100% of traces for 90 minutes during a routine Alloy DaemonSet rollout. The issue was a combination of two things: the `memory_limiter` was set to `limit_mib: 200` on a 256 MB container limit — that 200 MB limit was actually *above* what the container was allowed, so the limiter never fired, and the OOM killer won every time the DaemonSet pod on a high-traffic node restarted. The second issue was that the `sending_queue` had no storage configured, so the in-memory queue was wiped on each OOM restart. The fix: set `limit_mib` to 80% of the container limit, add file-backed queue storage, and — critically — add a `liveness_probe` on the `/metrics` endpoint rather than a TCP probe, so the readiness gate prevented a pod from accepting new data until its queue had drained from the previous pod's WAL. Always set `limit_mib` to `0.8 * resources.limits.memory_mib`.

---

## Checkpoint

You're ready for the collector challenges when you can, without looking anything up:

1. Draw the canonical processor order (3 processors) and explain why `memory_limiter` must be first.
2. State the difference between `limit_mib` and `spike_limit_mib`, and give the formula for setting each relative to the container's memory limit.
3. Write the ClusterRole rules that `k8sattributes` needs to enrich spans with pod metadata.
4. Explain why running apps without a collector in front of them (direct OTLP to backends) is risky for trace completeness during a backend outage.
5. Name two Alloy-specific benefits over the vanilla OTel Collector when running the full LGTM stack.
6. Diagnose a scenario where `k8s.pod.name` is missing from all spans: what are the three possible causes and the first command you run for each?
7. Explain what `zpages` shows and how you use it to confirm data is flowing through the pipeline.
8. Describe the failure mode when `limit_mib` is set equal to (not below) the container's memory limit.

➡ Next up: **Operating LGTM in Production** — multi-tenancy, object storage lifecycle, retention, meta-monitoring, and the cost/scale tradeoffs.
