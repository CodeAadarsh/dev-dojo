# SLO Recording Rule

Your SLO for the payments service is 99.9% availability over a 30-day rolling window. Your SLE wants a single metric they can chart and alert on — not raw counters that require a PromQL PhD to interpret, but a pre-computed ratio between 0 and 1. That's a **recording rule**.

A recording rule evaluates a PromQL expression on every scrape cycle and writes the result as a new time series under a chosen metric name. The SLI for an availability SLO is almost always a ratio: `good_requests / total_requests`. Recording rules exist because:

1. **Performance** — complex multi-join expressions are expensive. Pre-compute once, query many times.
2. **Reuse** — your dashboard, your burn-rate alert, and your quarterly report all query the same pre-built metric.
3. **Naming** — the [Prometheus recording rule naming convention](https://prometheus.io/docs/practices/rules/) (`level:metric:operations`) makes it clear what the series represents and at what aggregation level.

## Prereq

The `kube-prometheus-stack` must be installed:

```bash
bash labs/bootstrap/install-monitoring.sh
```

## Mission

Create a `PrometheusRule` resource in namespace `dojo-slo` that meets **all** of these conditions:

1. `apiVersion: monitoring.coreos.com/v1`, `kind: PrometheusRule`.
2. Label `release: kps` on the resource (same operator selector as the alerting challenge).
3. At least one group under `spec.groups[].rules[]` containing a **recording rule** (has a `record:` field, not `alert:`).
4. The recording rule's `record:` name follows the convention `level:metric:operations` — e.g. `job:http_requests_total:rate5m` or `job:request_success_ratio:rate5m`.
5. The rule's `expr` is non-empty and computes a ratio or rate — e.g. a `rate()` divided by another `rate()`, or a `sum(rate(...)) / sum(rate(...))` expression.

The verifier checks for the existence and shape of the PrometheusRule object and validates the recording rule structure. It does **not** require live metrics in the cluster.

## The SLI formula

For an HTTP-based service instrumented with the standard `http_requests_total{status=~"5.."}` counter:

```promql
# Error ratio (lower is better — invert to get success ratio)
sum(rate(http_requests_total{status=~"5.."}[5m]))
  /
sum(rate(http_requests_total[5m]))
```

The `record:` name would be something like `job:http_error_ratio:rate5m`.

For an availability SLO you want the **success** ratio (good / total), so flip the numerator to `status!~"5.."` — or compute `1 - error_ratio`.

The actual metric name doesn't have to match a real series in your cluster — the verifier checks structure, not runtime correctness. But use a real PromQL expression so the rule is deployable.

## Namespacing

Work in `dojo-slo`. Run `setup.sh` to create it.
