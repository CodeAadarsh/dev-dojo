# Solution — SLO Recording Rule

A PrometheusRule with a recording rule that computes a request success ratio:

```yaml
# slo-recording.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: dojo-slo-payments
  namespace: dojo-slo
  labels:
    release: kps          # required for Prometheus operator to pick this up
spec:
  groups:
    - name: dojo.slo.payments
      interval: 60s
      rules:
        - record: job:http_request_success_ratio:rate5m
          expr: |
            sum(rate(http_requests_total{status!~"5.."}[5m]))
              /
            sum(rate(http_requests_total[5m]))
```

Apply and verify:

```bash
kubectl apply -f slo-recording.yaml
bash courses/course-06-observability-lgtm/challenges/05-slo-recording-rule/verify.sh
```

## Why each piece matters

- **`record:` not `alert:`** — this is what distinguishes a recording rule from an alerting rule. The Prometheus operator evaluates the `expr` on every `interval` and stores the result as a new metric named `job:http_request_success_ratio:rate5m`.
- **`level:metric:operations` naming convention** — `job` is the aggregation level (by job label), `http_request_success_ratio` is the metric being computed, `rate5m` is the operation window. Following this convention means anyone who knows the convention can read the metric name and understand what it contains without reading the rule.
- **`status!~"5.."` in the numerator** — this is the "good" request count. `!~` is PromQL's "doesn't match regex" operator. HTTP 5xx responses are server errors; 4xx are client errors and typically excluded from availability SLIs (the server did its job; the client asked for something wrong).
- **`rate()` not `increase()` or raw counters** — `rate()` gives you a per-second rate smoothed over the window. Using raw counter values in a ratio would give wrong answers when the counter resets on pod restart. `rate()` handles resets correctly.

## Building a burn-rate alert on top of this

Once the recording rule is in place, a burn-rate alert is just a threshold on the ratio:

```yaml
- alert: PaymentsSLOBurnRateTooHigh
  expr: job:http_request_success_ratio:rate5m < 0.999
  for: 5m
  labels:
    severity: critical
  annotations:
    summary: "Payments SLO burning too fast"
    description: "Success ratio is {{ $value | humanizePercentage }} over the last 5 minutes."
```

This is the compound alerting pattern: recording rule computes the SLI, alerting rule fires on it. Keep them in the same `PrometheusRule` object or in separate ones — the operator merges all rules from all PrometheusRules it watches.

## Interpreting the output

Once deployed and the operator reloads (~30s), query Prometheus directly:

```bash
kubectl -n monitoring port-forward svc/prometheus-operated 9090:9090 &
# http://localhost:9090/graph?g0.expr=job%3Ahttp_request_success_ratio%3Arate5m
```

If `http_requests_total` doesn't exist in your cluster (it won't in a fresh kind setup), the metric returns no data — but the rule is correctly defined and would work in a cluster running an instrumented HTTP service.
