# Alerting, SLOs & Cardinality at Scale

> **Module 06 · Course 06** — When you run 100 GB+/day through a pipeline, two problems make each other worse: the alert configuration that felt reasonable at 10 GB/day now produces storms, and the high-cardinality metrics that seemed harmless cause Prometheus to OOM-kill itself. This module covers both, plus the SLO alerting model that replaces ad-hoc threshold alerts with principled burn-rate math.

You already have Alertmanager and recording rules in kube-prometheus-stack. This module makes them production-grade.

---

## Alertmanager routing and inhibition

Alertmanager receives fired alert notifications from Prometheus and decides: who gets paged, when, at what severity, and whether to suppress a child alert because a parent is already firing.

### The routing tree

```yaml
# alertmanager.yaml  (PrometheusRule or Helm values)
route:
  receiver: default-slack          # catch-all
  group_by: ['alertname', 'namespace']
  group_wait: 30s                  # wait before sending the first notification in a group
  group_interval: 5m               # how long to wait before re-notifying a changed group
  repeat_interval: 4h              # re-send an unresolved alert every N hours
  routes:
    - match:
        severity: critical
      receiver: pagerduty-sap
      continue: false              # stop routing after this branch
    - match:
        severity: warning
      receiver: slack-warnings
      group_wait: 2m               # warnings can wait longer
```

`group_by` is the most important knob. Without it, every alert fires a separate notification. With `['alertname', 'namespace']` you get one notification per unique `(alertname, namespace)` tuple, with new alerts added to the group as they fire. This is the primary defense against notification storms.

### Inhibition rules

Inhibition suppresses a child alert when a parent is already firing. Classic example: don't page on individual pod crashes if the whole node is `NotReady`.

```yaml
inhibit_rules:
  - source_match:
      alertname: NodeNotReady
    target_match_re:
      alertname: 'KubePodCrashLooping|KubePodNotReady'
    equal: ['node']               # only inhibit pods ON that specific node
```

Without inhibition, a single `NodeNotReady` event generates one parent alert plus one alert per pod on that node — potentially 50+ notifications. With the rule above, you get exactly one.

Another important pattern: inhibit `warning` when `critical` fires for the same job:

```yaml
inhibit_rules:
  - source_match:
      severity: critical
    target_match:
      severity: warning
    equal: ['alertname', 'namespace', 'pod']
```

---

## SLO alerting with burn-rate math

A **Service Level Objective** says: "99.9% of requests succeed over a 30-day window." That's your error budget: 0.1% × 30 days × 24 h × 60 min = **43.2 minutes of allowed downtime** per month.

A simple threshold alert on `error_rate > 1%` does not tell you whether you are burning your budget. You could burn through it in 4 hours at 10% error rate, or in 43 days at 0.1% — the same threshold fires in both cases, but only one is a page-worthy incident.

**Burn rate** = (current error rate) / (error budget rate). A burn rate of 1 = you are exactly on budget. Burn rate of 14.4 = you are burning 14.4× faster and will exhaust a 30-day budget in 50 hours.

### Multi-window burn-rate alerts (Google SRE book standard)

Use two windows to avoid both false pages (short windows are noisy) and slow detection (long windows are laggy):

```yaml
# PrometheusRule for a 99.9% SLO on the payment service
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: payment-slo-alerts
  namespace: monitoring
spec:
  groups:
    - name: payment.slo
      rules:
        # --- fast burn: 2% budget consumed in 1h = burn rate 14.4
        - alert: PaymentErrorBudgetBurnFast
          expr: |
            (
              job:payment_errors:rate1h / job:payment_requests:rate1h
            ) / 0.001 > 14.4
            and
            (
              job:payment_errors:rate5m / job:payment_requests:rate5m
            ) / 0.001 > 14.4
          for: 1m
          labels:
            severity: critical
            slo: payment
          annotations:
            summary: "Payment error budget burning fast (burn rate > 14.4x)"
            runbook: "https://wiki/runbooks/payment-slo"

        # --- slow burn: 5% budget consumed in 6h = burn rate 6
        - alert: PaymentErrorBudgetBurnSlow
          expr: |
            (
              job:payment_errors:rate6h / job:payment_requests:rate6h
            ) / 0.001 > 6
            and
            (
              job:payment_errors:rate30m / job:payment_requests:rate30m
            ) / 0.001 > 6
          for: 15m
          labels:
            severity: warning
            slo: payment
          annotations:
            summary: "Payment error budget burning slowly (burn rate > 6x)"
```

The `and` clause with a short window ensures the burn is still happening *now*, not just as a historical artifact of a spike that already resolved.

| Alert | Long window | Short window | Burn rate | Budget consumed before page |
|-------|------------|-------------|----------|----------------------------|
| Fast (critical) | 1h | 5m | 14.4× | 2% in 1h |
| Slow (warning) | 6h | 30m | 6× | 5% in 6h |
| Very slow (ticket) | 3d | 6h | 1× | budget tracking only |

---

## Recording rules for SLIs at scale

At 100 GB+/day, running raw `rate()` queries on high-cardinality metrics in alert rules is expensive — Prometheus re-evaluates every alert every `evaluation_interval` (default 1m). The solution: **recording rules** pre-aggregate SLI metrics into low-cardinality series that alert rules query instead.

Naming convention from the Prometheus docs: `level:metric:operation`.

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: payment-sli-recording
  namespace: monitoring
spec:
  groups:
    - name: payment.sli
      interval: 30s    # evaluate more often than alerts for fresh data
      rules:
        # sum errors across all pods — single series per job
        - record: job:payment_errors:rate5m
          expr: |
            sum without(pod, instance) (
              rate(http_requests_total{job="payment", status_code=~"5.."}[5m])
            )

        - record: job:payment_errors:rate1h
          expr: |
            sum without(pod, instance) (
              rate(http_requests_total{job="payment", status_code=~"5.."}[1h])
            )

        - record: job:payment_errors:rate6h
          expr: |
            sum without(pod, instance) (
              rate(http_requests_total{job="payment", status_code=~"5.."}[6h])
            )

        - record: job:payment_requests:rate5m
          expr: |
            sum without(pod, instance) (
              rate(http_requests_total{job="payment"}[5m])
            )

        - record: job:payment_requests:rate1h
          expr: |
            sum without(pod, instance) (
              rate(http_requests_total{job="payment"}[1h])
            )

        - record: job:payment_requests:rate6h
          expr: |
            sum without(pod, instance) (
              rate(http_requests_total{job="payment"}[6h])
            )
```

The alert rules above (`job:payment_errors:rate1h`) now query a single precomputed series instead of iterating over every pod time series. Query cost drops from O(pods × time-points) to O(1).

---

## Taming cardinality at 100 GB+/day

High cardinality is the #1 cause of Prometheus performance degradation at scale. Every unique label combination creates a new time series. A single label with 10,000 distinct values multiplied across 5 services = 50,000 series — and Prometheus keeps all active series in RAM.

### The cardinality math

```
active series ≈ (services × pods × unique label combinations)
RAM ≈ active series × 3–4 KB per series

10,000 series × 3 KB  = ~30 MB     (trivial)
1,000,000 series × 3 KB = ~3 GB    (Prometheus OOM at 2 GB limit)
```

### High-cardinality offenders and fixes

| Offender | Series explosion | Fix |
|----------|-----------------|-----|
| `user_id`, `session_id`, `request_id` labels | 1 series per user — unbounded | Drop at the Collector or relabeling rule; never instrument per-user |
| `pod` label in app metrics (not kube-state) | N series per pod × all replicas | Use `without(pod)` in recording rules; or relabel-strip at scrape |
| Raw URL path as label (`/api/users/12345`) | Unbounded — every unique ID is a path segment | Normalize in the app: `/api/users/{id}`; or use a regex relabeling drop |
| `version` label on every metric | New series every deploy | Keep `version` only on `info` metrics (a static gauge); join on dashboards |
| `status_code` as a string (`"200 OK"`) | One series per unique string | Use integer codes; or bucketize to `2xx/4xx/5xx` at the Collector |

### Prometheus drop/relabel rules at scrape time

The `metric_relabel_configs` block runs *after* scrape, before storage — it can drop or transform labels before they hit the TSDB.

```yaml
# in ServiceMonitor or PodMonitor
metricRelabelings:
  # drop any series with a high-cardinality user_id label
  - sourceLabels: [user_id]
    regex: .+
    action: drop

  # strip the pod label from app-generated metrics (keep it for kube-state)
  - sourceLabels: [__name__]
    regex: 'http_requests_total|http_request_duration.*'
    targetLabel: pod
    replacement: ''
    action: replace

  # drop metrics you never query (saves TSDB space immediately)
  - sourceLabels: [__name__]
    regex: 'go_gc_.*|promhttp_metric_handler_.*'
    action: drop
```

### Finding cardinality offenders

```bash
# which metric name has the most series?
kubectl -n monitoring port-forward svc/prometheus-operated 9090:9090 &
curl -s 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=topk(10, count by (__name__)({__name__!=""}))' | \
  python3 -c "
import sys, json
r = json.load(sys.stdin)
for m in r['data']['result']:
    print(m['value'][1].rjust(10), m['metric'].get('__name__',''))
"

# which label on a specific metric has the highest cardinality?
curl -s 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=count by (pod) (http_requests_total)' | \
  python3 -c "
import sys, json
r = json.load(sys.stdin)
print(len(r['data']['result']), 'distinct pod label values')
"
```

The Prometheus TSDB head stats endpoint gives you the raw cardinality index:

```bash
curl -s 'http://localhost:9090/api/v1/status/tsdb' | \
  python3 -c "
import sys, json
d = json.load(sys.stdin)['data']
print('headSeriesCount:', d.get('headStats',{}).get('numSeries','?'))
print('top labelNames:')
for l in d.get('labelValueCountByLabelName',[])[:10]:
    print(' ', str(l['count']).rjust(8), l['name'])
"
```

---

## Debugging Alerting, SLOs & Cardinality

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Alert fires and immediately resolves, cycles every few minutes | Metric is flapping across the threshold — noisy signal | Add `for: 5m` to the alert rule to require sustained firing; or smooth with a recording rule before alerting |
| Critical and warning both fire for the same service | Inhibition rule not matching — label values don't align | `amtool alert query` to inspect active alerts; confirm inhibit `equal` labels match exactly |
| Notification sent but Slack/PagerDuty not receiving it | Webhook URL invalid, or network egress blocked from Alertmanager pod | `kubectl -n monitoring logs deploy/kps-alertmanager | grep -i 'error\|failed'`; test with `amtool check-config` |
| Alert storm after a deploy: 50 pods all fire simultaneously | No `group_by` or too-specific grouping | Set `group_by: ['alertname','namespace']` and raise `group_wait` to allow flapping to settle |
| Burn-rate alert fires but `kubectl` shows pods healthy | Short window fired without the long window check | Ensure your alert `and`-es both windows; the short window alone is too sensitive |
| Prometheus OOM-killed, `kubectl describe pod` shows exit 137 | Active series count too high — cardinality explosion | Check `/api/v1/status/tsdb`; drop offending labels with `metric_relabel_configs`; lower `--storage.tsdb.retention.time` temporarily |
| Recording rule producing `NaN` | Divide-by-zero: denominator metric has no data for that label combo | Add `or vector(0)` defensive guard: `rate(errors[5m]) / (rate(requests[5m]) or vector(1))` |

### Exact diagnostic commands

Query Alertmanager's active alerts directly:

```bash
kubectl -n monitoring port-forward svc/kps-alertmanager 9093:9093 &
curl -s 'http://localhost:9093/api/v2/alerts?active=true' | \
  python3 -c "
import sys, json
alerts = json.load(sys.stdin)
for a in alerts:
    print(a['labels'].get('alertname'), a['status']['state'], a['labels'].get('namespace',''))
"
```

Check inhibition is working (alerts suppressed by inhibit rules won't appear as `active`):

```bash
curl -s 'http://localhost:9093/api/v2/alerts?inhibited=true' | \
  python3 -c "import sys,json; print(len(json.load(sys.stdin)), 'inhibited alerts')"
```

Validate Alertmanager config before applying:

```bash
kubectl -n monitoring exec -it deploy/kps-alertmanager -- \
  amtool check-config /etc/alertmanager/config/alertmanager.yaml
```

Force-fire a test alert to check routing end-to-end:

```bash
kubectl -n monitoring port-forward svc/kps-alertmanager 9093:9093 &
curl -s -X POST 'http://localhost:9093/api/v2/alerts' \
  -H 'Content-Type: application/json' \
  -d '[{"labels":{"alertname":"TestFire","severity":"warning","namespace":"dojo-test"},"annotations":{"summary":"routing test"}}]'
```

Check current TSDB series count and top cardinality offenders:

```bash
kubectl -n monitoring port-forward svc/prometheus-operated 9090:9090 &
curl -s 'http://localhost:9090/api/v1/status/tsdb' | \
  python3 -c "
import sys, json
d = json.load(sys.stdin)['data']
hs = d.get('headStats', {})
print('Series in head:', hs.get('numSeries','?'))
print('Chunks:', hs.get('numChunks','?'))
print()
print('Top 10 cardinality label names:')
for item in sorted(d.get('labelValueCountByLabelName',[]), key=lambda x: -x['count'])[:10]:
    print(' ', str(item['count']).rjust(8), item['name'])
"
```

> **War story.** The SAP LGTM pipeline was ingesting 100 GB+/day of logs and Prometheus was OOM-killing itself every 3–4 days under a 2 GB memory limit. The `kubectl describe pod` for the Prometheus pod showed OOMKilled. `tsdb` head stats showed 2.1M active series. The offender: the log processor emitted a `lgtm_log_line_count` metric with a `pipeline_stage` label that included the raw regex pattern being applied — and each new configuration deployment introduced new regex variants, so the label cardinality grew unboundedly. The fix: replace the `pipeline_stage` label value with a stable short name (`stage_01`, `stage_02`) in the Collector's `attributes` processor before export. Series count dropped to 180K; Prometheus stopped OOM-killing. The lesson: a metric is not just a number — it is a number multiplied by every unique label combination it can take. Before you add a label, ask: "What is the maximum cardinality of this label?" If the answer is "it depends on user input," the answer to adding it is no.

---

## Checkpoint

You are ready for the alerting and SLO challenges when you can, without looking anything up:

1. Explain what `group_by` in Alertmanager does and give the correct setting to prevent a 50-alert notification storm from a single node failure.
2. Write an inhibition rule that suppresses pod-level alerts when a `NodeNotReady` alert fires for the same node.
3. Calculate: for a 99.9% SLO over 30 days, what burn rate means 2% of the error budget is consumed in 1 hour? Show the arithmetic.
4. Explain why burn-rate SLO alerts `and` two windows (a long one and a short one) and what each window guards against.
5. Write recording rule names for the SLI error rate at 5m, 1h, and 6h windows following the `level:metric:operation` convention.
6. Name three label patterns that cause series explosions and give the fix for each.
7. Run the PromQL query that shows the top 10 metric names by series count.
8. Reproduce the SAP war-story bug in one sentence: what was the label, why did it grow unboundedly, and what was the fix.

→ You have completed the observability module sequence. Head to the challenges to put burn-rate alerting and cardinality tuning into practice on a live cluster.
