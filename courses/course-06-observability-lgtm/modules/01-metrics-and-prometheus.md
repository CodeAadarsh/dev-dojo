# Metrics & Prometheus

> **Module 01 · Course 06** — You're already pushing 100 GB+/day through an LGTM stack in production. This module is about understanding every layer of the pipeline that sits between an application and a Prometheus query so you can operate it, not just consume it.

You've used Grafana dashboards. Now you'll understand the machinery underneath them well enough to build, break, and fix every piece.

---

## The pull model — and why it matters

Every other metrics system you may have worked with (StatsD, CloudWatch, Datadog) is **push**: the application decides when to send data. Prometheus is **pull**: Prometheus decides when to scrape each target.

```
┌──────────────────────── pull cycle ────────────────────────────────────┐
│                                                                         │
│   Prometheus server                                                     │
│   ┌─────────────────┐   GET /metrics  (every 15 s default)             │
│   │  scrape_manager │ ──────────────────────────────────────► App pod  │
│   │                 │ ◄──────────────────────── 200 OK, text/plain     │
│   │  TSDB (chunks)  │  stores (labels, unix_timestamp, float64 value)  │
│   └────────┬────────┘                                                   │
│            │ push on eval                                               │
│   ┌────────▼────────┐                                                   │
│   │  Alertmanager   │  deduplicate → route → PagerDuty / Slack        │
│   └─────────────────┘                                                   │
│                                                                         │
│   Grafana  ─── PromQL over HTTP ──► Prometheus                         │
└─────────────────────────────────────────────────────────────────────────┘
```

The pull model gives you three things worth internalizing:

- **Scrape failures are first-class signals.** If Prometheus can't reach a target, the synthetic metric `up{job="...", instance="..."}` is set to `0`. A push-based system is silent when the producer dies — you only notice when data stops arriving. Prometheus actively reports the absence.
- **Configuration is centralized.** What gets collected is controlled in one place (Prometheus's scrape config, or the `ServiceMonitor` CRDs). Applications don't need to know who consumes their metrics.
- **No firewall holes from pod → monitoring.** The app exposes a plain HTTP endpoint; Prometheus calls into it. The network topology is simple and auditable.

The tradeoff: targets must be **discoverable**. In Kubernetes this is solved by `kubernetes_sd_configs`, which uses the Kubernetes API to enumerate Pods and Services and build the target list dynamically as pods come and go.

---

## Exposition format

The `/metrics` endpoint returns **plain text** in the Prometheus exposition format. No protobuf, no JSON by default — just lines. A real response:

```
# HELP http_requests_total Total number of HTTP requests handled
# TYPE http_requests_total counter
http_requests_total{method="GET",status="200"} 12345
http_requests_total{method="GET",status="500"} 7
http_requests_total{method="POST",status="200"} 891

# HELP http_request_duration_seconds Latency distribution
# TYPE http_request_duration_seconds histogram
http_request_duration_seconds_bucket{le="0.005"} 8800
http_request_duration_seconds_bucket{le="0.025"} 10100
http_request_duration_seconds_bucket{le="0.1"}   10900
http_request_duration_seconds_bucket{le="0.5"}   11040
http_request_duration_seconds_bucket{le="+Inf"}  11050
http_request_duration_seconds_sum   1234.5
http_request_duration_seconds_count 11050

# HELP up Target scrape health
# TYPE up gauge
up 1
```

**The four metric types you'll encounter everywhere:**

| Type | Behavior | When to use |
|------|----------|-------------|
| **counter** | monotonically increases, resets only on restart | request count, error count, bytes sent/received |
| **gauge** | arbitrary float, can go up or down | memory in use, queue depth, active connections, temperature |
| **histogram** | tracks observations in pre-defined buckets + `_sum` + `_count` | latency, request body size — gives you percentiles at query time |
| **summary** | pre-computes quantiles client-side + `_sum` + `_count` | latency when percentile bucket boundaries are known ahead of time |

> **Histogram beats summary at scale.** Summary quantiles are computed inside the process and cannot be aggregated across replicas — you can't get "p99 across all 30 billing pods." Histogram `_bucket` counts *can* be summed across replicas first, then `histogram_quantile()` is applied. Always prefer histogram unless you have a compelling client-side reason.

---

## Exporters

Most software doesn't ship a `/metrics` endpoint. **Exporters** bridge that gap: they speak to an external system and translate its state into Prometheus exposition format.

| Exporter | What it exposes | How it runs in k8s |
|----------|----------------|-------------------|
| `node_exporter` | host CPU, memory, disk I/O, filesystem, network | DaemonSet, one per node |
| `kube-state-metrics` | K8s object state: pod phase, deployment replica counts, PVC bound/pending | Deployment, cluster-wide |
| `cadvisor` | per-container resource usage (CPU cycles, memory RSS, network bytes) | embedded in kubelet, at `/metrics/cadvisor` |
| `blackbox_exporter` | HTTP/TCP/DNS/ICMP probe results (is endpoint reachable, what did it return) | Deployment, drives synthetic monitoring |
| `postgres_exporter` | query latency, active connections, replication lag, lock waits | sidecar or separate Deployment |
| your app | business metrics — request rates, queue depths, domain counters | any language's Prometheus client library |

**kube-state-metrics and cadvisor are not the same thing:**

```bash
# cadvisor tells you: how much CPU is container "api" actually consuming right now?
container_cpu_usage_seconds_total{pod="api-7f9d8-xyz", container="api"}

# kube-state-metrics tells you: is the Deployment at its desired replica count?
kube_deployment_status_replicas_available{deployment="billing"}
kube_deployment_spec_replicas{deployment="billing"}
```

cadvisor measures *resource consumption*; kube-state-metrics measures *Kubernetes object state*. You need both for meaningful dashboards. The kube-prometheus-stack installs both automatically.

---

## Scrape config and relabeling

Prometheus's scrape configuration has two phases: **service discovery** (what addresses exist) and **relabeling** (should I scrape this address, and with what labels).

A Kubernetes pod scrape config in raw `prometheus.yaml`:

```yaml
scrape_configs:
  - job_name: kubernetes-pods
    kubernetes_sd_configs:
      - role: pod                        # ask the k8s API for all pods

    relabel_configs:
      # drop pods that haven't opted in
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
        action: keep
        regex: "true"

      # respect a custom port annotation if set
      - source_labels: [__meta_kubernetes_pod_ip,
                        __meta_kubernetes_pod_annotation_prometheus_io_port]
        action: replace
        separator: ":"
        target_label: __address__
        regex: (.+):(.+)
        replacement: $1:$2

      # promote namespace + pod name as permanent metric labels
      - source_labels: [__meta_kubernetes_pod_namespace]
        target_label: namespace
      - source_labels: [__meta_kubernetes_pod_name]
        target_label: pod
      - source_labels: [__meta_kubernetes_pod_label_app]
        target_label: app
```

`__meta_kubernetes_*` labels are populated by the `kubernetes_sd_configs` discovery mechanism. They exist only during relabeling; they are **stripped** before samples are stored. You must explicitly `replace` them into permanent labels if you want to query by namespace or pod name later.

**Two relabeling hooks:**

| Config key | When it runs | Purpose |
|-----------|-------------|---------|
| `relabel_configs` | before the scrape | decide whether to scrape, and set `__address__`, `__metrics_path__`, etc. |
| `metric_relabel_configs` | after the scrape, per series | rewrite or drop individual metrics before storing |

A common `metric_relabel_configs` pattern — drop high-cardinality runtime internals you'll never query:

```yaml
metric_relabel_configs:
  - source_labels: [__name__]
    regex: 'go_(gc_duration_seconds|memstats_gc_cpu_fraction|goroutines)'
    action: drop
```

---

## kube-prometheus-stack and the operator CRDs

The `kube-prometheus-stack` Helm chart installs the **Prometheus Operator**, which introduces CRDs so you configure Prometheus scraping through Kubernetes YAML instead of editing a raw config file and restarting Prometheus.

Install it (resource-heavy — give Docker Desktop ≥ 5 GB):

```bash
bash labs/bootstrap/install-monitoring.sh
```

Verify:

```bash
kubectl -n monitoring get pods
# kps-prometheus-node-exporter-*      (DaemonSet, one per node)
# kps-kube-state-metrics-*            (Deployment)
# alertmanager-kps-kube-prometheus-*  (StatefulSet)
# prometheus-kps-kube-prometheus-*    (StatefulSet)
# kps-grafana-*                       (Deployment)
```

### ServiceMonitor

Tells the Operator which **Services** to scrape:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: billing-metrics
  namespace: dojo-observe
  labels:
    release: kps                       # MUST match Prometheus's serviceMonitorSelector
spec:
  selector:
    matchLabels:
      app: billing                     # targets Services with this label
  namespaceSelector:
    matchNames:
      - dojo-observe
  endpoints:
    - port: metrics                    # named port on the Service
      interval: 15s
      path: /metrics
```

### PodMonitor

Like ServiceMonitor but selects **Pods** directly — useful when there is no backing Service:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: sidecar-metrics
  namespace: dojo-observe
  labels:
    release: kps
spec:
  selector:
    matchLabels:
      monitoring: "true"
  podMetricsEndpoints:
    - port: metrics
      interval: 30s
```

### PrometheusRule

Alerting and recording rules as a CRD:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: billing-alerts
  namespace: dojo-observe
  labels:
    release: kps
spec:
  groups:
    - name: billing.availability
      interval: 30s
      rules:
        - alert: BillingDown
          expr: up{job="billing-metrics"} == 0
          for: 2m
          labels:
            severity: critical
          annotations:
            summary: "Billing service scrape target is down for 2m"
```

> **The `release: kps` label is not optional.** By default, the Prometheus Operator only watches `ServiceMonitor` and `PrometheusRule` objects whose labels match `serviceMonitorSelector: {matchLabels: {release: kps}}`. A `ServiceMonitor` without this label is silently ignored — the target never appears in Prometheus. Check the selector with: `kubectl -n monitoring get prometheus kps-kube-prometheus-stack-prometheus -o jsonpath='{.spec.serviceMonitorSelector}'`

---

## metrics-server vs Prometheus

A common confusion: both expose CPU and memory numbers. They are not interchangeable.

| | metrics-server | Prometheus + cadvisor |
|---|---|---|
| **Purpose** | HPA/VPA autoscaler signal + `kubectl top` | Long-term storage, alerting, dashboards, PromQL |
| **Retention** | ~1 minute (pure in-memory, no persistence) | Days to weeks (configurable TSDB retention) |
| **Granularity** | Per-pod, aggregated | Per-container, full label set |
| **Autoscaling** | Built-in (CPU/memory) | Via `prometheus-adapter` (custom metrics HPA) |
| **Historical queries** | Impossible — no history stored | Core capability |
| **Install** | `bash labs/bootstrap/install-metrics-server.sh` | `bash labs/bootstrap/install-monitoring.sh` |

metrics-server is a **hard dependency** for `kubectl top pods`, `kubectl top nodes`, and CPU/memory HPA. Without it, your HPA will log `unable to get metrics for resource cpu`. Without Prometheus you have no history, no alerting, and no dashboards. A production cluster needs both.

---

## Debugging Prometheus Targets

The canonical first stop: **Prometheus UI → Status → Targets**. But the UI alone won't tell you *why* a target is failing. Use this table.

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Target `state: DOWN`, error `connection refused` | Pod/Service at that address is gone, crashed, or wrong port | `kubectl -n <ns> get pods -o wide` — confirm pod IP and the metrics port is in the container spec |
| Target `state: DOWN`, error `context deadline exceeded` | NetworkPolicy blocking Prometheus pod → metrics port | Add an Ingress rule on the metrics port from the `monitoring` namespace CIDR |
| Target appears `UP` but `up` metric is `0` or absent | App is reachable but `/metrics` returns non-2xx | `kubectl exec -n monitoring <prom-pod> -c prometheus -- wget -qO- http://<pod-ip>:<port>/metrics` |
| Target never appears in the UI at all | `ServiceMonitor` missing `release: kps` label, wrong `namespaceSelector`, or wrong port name | Compare `serviceMonitorSelector` on the Prometheus CRD to your ServiceMonitor's labels |
| Metrics present but stale (`last scrape 8m+` in UI) | Prometheus is resource-starved (slow scrape loops) or scrape interval too long | Check `prometheus_target_scrape_pool_exceeded_sample_limit_total`; raise memory, or reduce targets |
| Metrics dropped silently after deploy | `metric_relabel_configs` drop rule too broad, or sample limit hit | Temporarily comment out `metric_relabel_configs`; check `prometheus_target_scrapes_exceeded_sample_limit_total` |

### Exact diagnostic commands

**Confirm the metrics port is reachable from inside Prometheus's pod:**

```bash
PROM_POD=$(kubectl -n monitoring get pods -l app.kubernetes.io/name=prometheus -o name | head -1 | sed 's|pod/||')
kubectl -n monitoring exec "$PROM_POD" -c prometheus -- \
  wget -qO- http://<pod-ip>:<port>/metrics | head -20
```

**List all targets via the Prometheus HTTP API:**

```bash
kubectl -n monitoring port-forward svc/prometheus-operated 9090:9090 &
curl -s 'http://localhost:9090/api/v1/targets?state=active' \
  | python3 -c "
import sys, json
targets = json.load(sys.stdin)['data']['activeTargets']
for t in targets:
    print(t['health'], t['labels'].get('job','?'), t.get('lastError',''))
"
```

**Why is a ServiceMonitor ignored? Compare selectors:**

```bash
kubectl -n monitoring get prometheus kps-kube-prometheus-stack-prometheus \
  -o jsonpath='{.spec.serviceMonitorSelector}{"\n"}'
kubectl -n dojo-observe get servicemonitor billing-metrics \
  -o jsonpath='{.metadata.labels}{"\n"}'
```

**Test whether a NetworkPolicy is blocking the scrape:**

```bash
kubectl run probe --rm -it --image=nicolaka/netshoot -n monitoring -- \
  curl -s http://<pod-ip>:<port>/metrics | head -5
```

**Check sample limit violations:**

```bash
kubectl -n monitoring port-forward svc/prometheus-operated 9090:9090 &
# in another terminal:
curl -sg 'http://localhost:9090/api/v1/query?query=prometheus_target_scrapes_exceeded_sample_limit_total' \
  | python3 -c "import sys,json; [print(r['metric'].get('job','?'), r['value'][1]) for r in json.load(sys.stdin)['data']['result']]"
```

> **War story.** At SAP, our LGTM pipeline started silently dropping ~30% of pod scrapes for six hours before anyone noticed. The Prometheus target page showed those pods `UP` — but `up == 1` is only recorded at the moment of a successful scrape, and the pod had restarted in the window between the failed scrape and our check. The real signal was `prometheus_target_scrapes_exceeded_sample_limit_total` incrementing on a noisy subset of pods. Root cause: an instrumentation PR introduced a per-request label that included trace IDs — an effectively unbounded cardinality label on a counter, creating 40,000+ series from a single pod. Prometheus was silently rejecting those entire scrapes against the configured sample limit. The fix was `metric_relabel_configs` to drop the offending metric family at ingest. The rule of thumb that came out of the post-mortem: any instrumentation PR that adds a label with user-controlled values goes to `metric_relabel_configs` review first.

---

## Checkpoint

You're ready for the challenges when you can, without looking anything up:

1. Explain the pull model and name one failure mode it surfaces that a push-based system would hide.
2. Distinguish `histogram` from `summary` — explain why summary quantiles can't be aggregated across replicas and histogram buckets can.
3. State what `kube-state-metrics` exposes that `cadvisor` does not, and why you need both.
4. Create a `ServiceMonitor` for a running Deployment, confirm it appears in Prometheus UI → Status → Targets, and explain why the `release: kps` label is required.
5. Describe `relabel_configs` vs `metric_relabel_configs` — when does each run, and what is each used for?
6. Run the exact `wget` command from inside the Prometheus pod to confirm whether a pod's metrics endpoint is reachable.
7. Name the Prometheus metric that tells you scrapes are being rejected due to sample limit violations, and explain what causes them.
8. Explain why `metrics-server` is not a substitute for Prometheus, and name the two scenarios where you need `metrics-server` specifically.

➡ Next up: **PromQL That Earns Its Keep** — you have the data; now learn to ask it the right questions.
