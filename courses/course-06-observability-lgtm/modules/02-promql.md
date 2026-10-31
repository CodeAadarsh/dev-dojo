# PromQL That Earns Its Keep

> **Module 02 · Course 06** — PromQL is a time-series query language with a handful of sharp edges that trip up even experienced users. This module covers the constructs you'll reach for daily: rate/increase, aggregation, histogram percentiles, recording rules, and the failure modes that produce silently wrong answers.

Assume you have Prometheus running with kube-prometheus-stack. All examples are executable as-is in the Prometheus UI (port-forward `svc/prometheus-operated 9090:9090`).

---

## Instant vectors vs range vectors

Every PromQL expression returns one of two things: an **instant vector** or a **range vector**. Getting this wrong is the root of most "why is my query broken" moments.

**Instant vector** — a set of time series, each with exactly one sample at the evaluation time:

```promql
http_requests_total
# returns: one row per label combination, value = most recent sample
```

**Range vector** — a set of time series, each with a *window* of samples from the past `[d]`:

```promql
http_requests_total[5m]
# returns: all samples in the last 5 minutes for each series
# NOT directly graphable — range vectors are inputs to functions like rate()
```

You cannot graph a range vector directly. You pass it to a function that aggregates the window into a single value:

```promql
rate(http_requests_total[5m])           # per-second rate over 5m window
increase(http_requests_total[5m])       # total increase over 5m
irate(http_requests_total[5m])          # instantaneous rate (last 2 samples only)
```

The `[5m]` window must be **at least 4× the scrape interval**. With a 15-second scrape interval, `[1m]` gives you at most 4 samples — statistically unreliable for rate calculation. Use `[5m]` for dashboards, `[1m]` only if you truly need the tightest lag.

---

## rate() and increase()

These are the two functions you use for every counter metric. Counters only increase; `rate()` and `increase()` handle counter resets (pod restarts) by detecting a drop and adjusting.

### rate()

Returns the per-second average rate of increase over the window:

```promql
# per-second HTTP request rate, averaged over 5 minutes
rate(http_requests_total{job="billing"}[5m])
```

When to use `rate()`: anytime you want a **throughput** or **error rate** in "per second." It smooths over the window, making it better for dashboards and alerts.

### increase()

Returns the total increase over the window (not per-second):

```promql
# total requests in the last 5 minutes
increase(http_requests_total{job="billing"}[5m])
```

When to use `increase()`: when you want a count over a time range — "how many errors happened in the last hour?" Note: `increase(x[5m])` is exactly `rate(x[5m]) * 5 * 60`. It's a convenience wrapper; they're equivalent.

### irate()

Uses only the **last two data points** in the window:

```promql
irate(http_requests_total{job="billing"}[5m])
```

`irate()` is more sensitive to spikes (useful for spike detection alerts) but produces noisy graphs. Avoid it for dashboards; prefer `rate()`.

> **The window determines accuracy, not just lag.** `rate(x[1m])` over a 15-second scrape interval uses 4 samples. If one is missed (pod restarted, brief network blip), you're down to 3 or 2 samples — rate confidence plummets. The rule: window `>= 4 * scrape_interval`. For production alerts where false-fires are expensive, use `[5m]` minimum.

---

## Aggregation: by / without

Raw `rate()` returns one series per unique label combination. You almost always want to aggregate across some dimension.

**`sum by`** — collapse all label combinations down to only the ones you name:

```promql
# total request rate grouped by HTTP method (drops pod, namespace, instance, etc.)
sum by (method) (rate(http_requests_total[5m]))
```

**`sum without`** — keep all labels except the ones you name:

```promql
# total rate per everything-except-pod (i.e. per namespace+job+method)
sum without (pod, instance) (rate(http_requests_total[5m]))
```

**`by` is almost always the right choice** for explicit, maintainable queries. `without` is fragile: if a new label is added to the metric, it silently shows up in your aggregation output.

### The aggregation operators

```promql
sum by (namespace) (rate(http_requests_total[5m]))   # total rate per namespace
avg by (node)      (node_cpu_seconds_total)           # avg CPU per node
max by (pod)       (container_memory_rss)             # highest RSS per pod
min by (job)       (up)                               # is any instance down?
count by (phase)   (kube_pod_status_phase)            # pods per phase
topk(5, sum by (pod) (rate(http_requests_total[5m]))) # top-5 pods by request rate
bottomk(3, kube_deployment_status_replicas_available) # deployments with fewest ready
```

### Binary operations

PromQL supports arithmetic and comparison between instant vectors. Labels must match for the operation to bind:

```promql
# error rate as a fraction of total rate
sum by (job) (rate(http_requests_total{status=~"5.."}[5m]))
/
sum by (job) (rate(http_requests_total[5m]))
```

When labels don't match exactly, use `on()` or `ignoring()`:

```promql
# memory used / memory limit per pod
container_memory_working_set_bytes
/
on(pod, namespace, container) container_spec_memory_limit_bytes
```

---

## histogram_quantile and the percentile math

The histogram metric type stores observations in pre-defined buckets. To get a percentile from it:

```promql
histogram_quantile(
  0.99,
  sum by (le) (rate(http_request_duration_seconds_bucket[5m]))
)
```

The breakdown:
1. `http_request_duration_seconds_bucket` — the raw bucket counters (one series per `le` boundary)
2. `rate(...[5m])` — convert buckets from counters to per-second rates (handling resets)
3. `sum by (le) (...)` — aggregate across all instances/pods, keeping bucket boundaries (`le` = less-than-or-equal)
4. `histogram_quantile(0.99, ...)` — Prometheus interpolates linearly within the bucket that contains the 99th percentile

**Why `sum by (le)` and not just `sum()`?** The `histogram_quantile()` function needs the `le` label to know which bucket is which. Strip it and you get an error.

### The percentile labels pattern

A frequent requirement: p99 broken down by service or endpoint.

```promql
histogram_quantile(
  0.99,
  sum by (le, job, handler) (
    rate(http_request_duration_seconds_bucket{job="billing"}[5m])
  )
)
```

Keep only the labels you want in the result in the `sum by` list, plus `le`.

---

## Why you cannot average percentiles

This is the single most common PromQL mistake in production dashboards. It produces confidently wrong numbers.

```promql
# WRONG: averages the p99 from each pod — meaningless
avg(histogram_quantile(0.99, rate(http_request_duration_seconds_bucket[5m])))

# CORRECT: sum the bucket counts first, then compute p99 across the fleet
histogram_quantile(
  0.99,
  sum by (le) (rate(http_request_duration_seconds_bucket[5m]))
)
```

**Why averaging percentiles is wrong:** `p99 = 200ms` on pod A and `p99 = 1000ms` on pod B does not mean fleet p99 is `600ms`. The 99th percentile is a positional statistic — it depends on the full distribution, not just the per-pod summaries. By summing the raw buckets across pods before calling `histogram_quantile`, you reconstruct the full fleet distribution and then find the true p99 position in it.

The same logic applies to summaries: you cannot sum or average summary quantiles from multiple replicas. This is why histograms are preferred at scale.

---

## Recording rules

PromQL queries that are expensive — fanout over many series, complex aggregations — can be **pre-computed** on a schedule and stored as new metric series. This is what recording rules are for.

A recording rule in a `PrometheusRule` CRD:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: billing-recording-rules
  namespace: dojo-observe
  labels:
    release: kps
spec:
  groups:
    - name: billing.slo
      interval: 30s
      rules:
        # pre-compute request rate per namespace — used by multiple dashboards
        - record: job:http_requests:rate5m
          expr: |
            sum by (job, namespace) (
              rate(http_requests_total[5m])
            )

        # pre-compute error ratio per job
        - record: job:http_error_ratio:rate5m
          expr: |
            sum by (job) (rate(http_requests_total{status=~"5.."}[5m]))
            /
            sum by (job) (rate(http_requests_total[5m]))

        # pre-compute p99 latency fleet-wide per job
        - record: job:http_request_duration_seconds:p99_5m
          expr: |
            histogram_quantile(
              0.99,
              sum by (le, job) (
                rate(http_request_duration_seconds_bucket[5m])
              )
            )
```

**Recording rule naming convention:** `<aggregation_level>:<metric_name>:<operations>`. The standard prefixes: `job:`, `instance:`, `cluster:`. This is a Prometheus operator convention — not enforced, but widely followed.

**When to write recording rules:**
- Any query used on a Grafana dashboard that spans thousands of series
- Any alert `expr` that takes > 1 second to evaluate (check `prometheus_rule_evaluation_duration_seconds`)
- Any computation that appears in more than one place (DRY for PromQL)

---

## Debugging PromQL

### Counter resets

**Symptom:** `rate()` or `increase()` returns a value lower than expected, or you see a brief dip to near-zero at restart boundaries.

**How resets work:** when a counter resets (process restart), its value drops. Prometheus detects any drop in a counter as a reset event and adds the previous value to the current reading. This usually produces the right answer, but with a short window and multiple restarts, the heuristic can undercount.

**Diagnose:**

```promql
# see the raw counter with jumps visible
http_requests_total{job="billing"}

# check for resets in the window explicitly
resets(http_requests_total{job="billing"}[5m])
# > 0 means at least one reset happened in this window
```

If you're seeing suspect rate drops, widen the window (`[15m]` instead of `[5m]`) to reduce the fraction of window the reset-gap occupies.

### Staleness

**Symptom:** a series disappears from a query result at a specific timestamp; graph has gaps; alerts fire briefly for pods that are healthy.

**Cause:** Prometheus marks a series as **stale** 5 minutes after the last scrape for it. Once stale, the series returns no data for that timestamp. This is correct behavior — it prevents old data from being returned for dead pods — but it interacts badly with short scrape intervals, flapping pods, or targets that come and go.

```promql
# detect stale series: no data in the last 10 minutes for a series that existed before
absent_over_time(up{job="billing"}[10m])
# returns 1 if the series is absent; use in alerts
```

**Debugging staleness:**

| Symptom | Cause | Fix |
|---------|-------|-----|
| Graph gap every time a pod restarts | Stale marker + new pod gets a new `pod` label value | Normal; widen panel time range to see continuity |
| Alert fires for 5m after a deploy | Old pod series go stale; alert window overlaps | Add `for: 10m` to the alert; or filter on `pod` label if pod count matters |
| Entire job disappears from instant vector | All targets for that job went DOWN simultaneously | Check Prometheus target health; look for service disruption |

**The 5-minute lookback:** by default, PromQL instant queries look back up to 5 minutes for the most recent sample. If no sample is found within that window, the series returns no data. You can expand the lookback with the `@` modifier or by widening the query range.

### Slow queries

**Symptom:** Grafana dashboard loads in 10+ seconds, or Prometheus UI is sluggish.

| Symptom | Cause | Fix |
|---------|-------|-----|
| High `prometheus_engine_query_duration_seconds` | Query over too many series (high cardinality label); no recording rule | Add `sum by` to reduce fanout; add recording rule |
| Slow dashboards after adding new labels to metrics | New labels multiply series count | Review if the label is truly needed; remove or use `metric_relabel_configs` to drop it |
| `Err: query timed out in expression evaluation` | Query touches > 100k+ series | Break up query; use recording rules for sub-expressions |
| Dashboard fast at small time ranges, slow at large | More raw chunks to load | Add recording rule for the expensive subquery |

**Diagnose expensive queries:**

```bash
kubectl -n monitoring port-forward svc/prometheus-operated 9090:9090 &
# check the query log for slow queries
curl -s 'http://localhost:9090/api/v1/query?query=topk(10, prometheus_engine_query_duration_seconds_sum)' \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)['data']['result']
for r in sorted(data, key=lambda x: float(x['value'][1]), reverse=True):
    print(r['value'][1], r['metric'].get('slice','?'))
"
```

**Check how many series a metric has:**

```promql
count(http_requests_total)
# returns total number of active series

count by (job) (http_requests_total)
# per-job series count — find which job contributes the most
```

> **War story.** We had a Grafana dashboard that was loading in 45 seconds on the production Prometheus — not enough to be paged about, too slow to be usable. The guilty panel was a p99 query with no `sum by`: `histogram_quantile(0.99, rate(http_request_duration_seconds_bucket[5m]))`. It was fanning out across 300 pods × 15 buckets × 8 handlers = 36,000 series before calling `histogram_quantile`. Adding `sum by (le, job, handler)` dropped the fanout to 120 series and the panel load time to under 2 seconds. The lesson: every `histogram_quantile` expression needs an explicit `sum by (le, ...)` — without it, Prometheus computes a separate p99 per instance (usually not what you want), and pays the fanout cost of every series in the metric family.

---

## Checkpoint

You're ready for the challenges when you can, without looking anything up:

1. Explain the difference between an instant vector and a range vector, and name one function that consumes each.
2. Write a `rate()` query for a counter metric — pick the correct window for a 15-second scrape interval and explain why.
3. Write a query that gives error rate as a fraction of total request rate, aggregated by `job`.
4. Write a correct `histogram_quantile(0.99, ...)` query for fleet-wide p99 latency — explain why the `sum by (le)` is mandatory.
5. Explain in one sentence why averaging p99 values across pods produces a wrong answer, and what you do instead.
6. Write a recording rule that pre-computes per-job error ratio and name it correctly per the convention.
7. Diagnose counter resets in a live `rate()` result — what PromQL tells you how many resets happened in a window?
8. Given a Grafana dashboard loading in 30 seconds, name three PromQL-side causes and one fix for each.

➡ Next up: **Logs & Loki** — structured logging, LogQL, and the cardinality trap that can OOM your Loki instance.
