# SLIs, SLOs, Error Budgets & Alerting

> **Module 06 · Course 02** — Module 01 gave you the *vocabulary* of reliability: what an SLI, SLO, and error budget are, and why you alert on burn rate instead of a static threshold. This module is where that vocabulary becomes YAML, PromQL, and a dashboard you'd actually page off of. We go from "99.9% is the target" to the exact recording rules, the Alertmanager routing tree, and the Grafana panels that turn an abstract objective into something your on-call can defend at 3am.

You already run the LGTM stack at work, so this is deliberately fast on "what is Prometheus" and slow on the parts that separate a dashboard that looks impressive in a demo from one that actually catches outages before your customers tweet about them. The install reference for everything below is `labs/bootstrap/install-monitoring.sh` — it stands up `kube-prometheus-stack` (Prometheus + Grafana + Alertmanager + node/kube-state-metrics) in the `monitoring` namespace. Have it running before the hands-on sections.

```bash
bash labs/bootstrap/install-monitoring.sh
kubectl -n monitoring get pods          # wait for kps-* and prometheus-kps-* Running
kubectl -n monitoring port-forward svc/kps-grafana 3000:80   # admin / admin
```

---

## From indicator to objective — the implementation chain

Module 01 drew the SLI → SLO → SLA chain conceptually. Here is the same chain as the artifacts you commit, one per rung:

```
 ┌── SLI ──────────────┐   ┌── SLO ───────────────┐   ┌── Alert ─────────────┐
 │ a PromQL ratio of   │──▶│ a target + window     │──▶│ multi-window         │
 │ good / valid events │   │ stored as a constant  │   │ burn-rate rules on   │
 │ (a recording rule)  │   │ in a recording rule   │   │ the SLI vs the budget│
 └─────────────────────┘   └───────────────────────┘   └──────────────────────┘
   `sli:availability`        `slo:target = 0.999`        `ErrorBudgetBurn` page
```

The discipline that matters: **every one of those is a named recording rule, never an inline expression buried in an alert.** The moment a human is staring at a firing alert at 3am, they must be able to click through to *why* — and a wall of nested `rate()` calls is not a why. Named rules (`sli:http_availability:ratio_rate5m`) are self-documenting and they're evaluated once and cached, so your dashboards and alerts read the same pre-computed number instead of recomputing an expensive query per panel.

---

## Defining an SLI that survives contact with production

An SLI is a ratio of **good events** over **valid events**. The whole craft is in those two definitions. Get them wrong and a perfectly green dashboard sits on top of an angry customer.

The three SLI *types* you'll actually use, and when:

| SLI type | Good / valid definition | Reach for it when |
|----------|-------------------------|-------------------|
| **Availability** | non-5xx responses / all valid responses | Every request-driven service — the default |
| **Latency** | requests served under threshold / all valid requests | Users feel slowness before they feel errors |
| **Freshness / correctness** | records processed within N min / all records | Pipelines, batch, async (your LGTM ingest) |

### Availability SLI as a recording rule

```promql
# good events: requests that did NOT return a 5xx
# valid events: all requests EXCEPT 4xx caused by the client
record: sli:http_requests_good:rate5m
expr: sum(rate(http_requests_total{code!~"5.."}[5m])) by (service)

record: sli:http_requests_valid:rate5m
expr: sum(rate(http_requests_total{code!~"4.."}[5m])) by (service)

record: sli:http_availability:ratio_rate5m
expr: sli:http_requests_good:rate5m / sli:http_requests_valid:rate5m
```

Note the denominator excludes `4xx`. A client sending garbage and getting a `400` is **not** your reliability failing — counting it burns your budget for someone else's bug. But be honest: a `400` your own validation regression caused *is* your failure. Deciding what is "valid" is where most SLI definitions quietly rot. Write the definition down next to the rule so the next engineer knows the call you made.

### Latency SLI — count the fast ones, don't average

The classic mistake is `histogram_quantile(0.99, ...)` as your SLI and alerting when p99 crosses a line. p99 is a *diagnostic*, not an SLI, because it tells you nothing about *how many* users were slow. The SLI is a **ratio**: what fraction of requests came in under the threshold.

```promql
# fraction of requests served under 300ms (the "le" bucket boundary must exist)
record: sli:http_latency_fast:ratio_rate5m
expr: |
  sum(rate(http_request_duration_seconds_bucket{le="0.3"}[5m])) by (service)
  /
  sum(rate(http_request_duration_seconds_count[5m])) by (service)
```

This only works if your histogram has a bucket boundary *at* your SLO threshold. If your SLO is "95% under 300ms" but your histogram's nearest `le` buckets are `0.25` and `0.5`, you cannot measure your own SLO — you'll silently round to the wrong bucket. **Pick histogram buckets to match your SLO thresholds, not the library defaults.** This is the single most common reason a latency SLI reads as a suspiciously round number.

> **The averages trap, made concrete.** A service with `avg(http_request_duration_seconds) = 0.08` looks healthy. But if 5% of traffic sits at 4 seconds and 95% at 10ms, the average is still ~0.08 and your dashboard is green while one in twenty users rage-quits. The ratio SLI exposes exactly this: it reads `0.95`, you see the 5% miss directly, and it maps one-to-one onto an error budget. The mean is a lie the tail tells.

---

## SLO targets and the error budget, as queryable numbers

Pin the SLO target itself as a recording rule so there is exactly one place to change it:

```promql
record: slo:http_availability:target
expr: vector(0.999)          # 99.9% — change here, everything downstream follows
```

The **error budget remaining** over the SLO window is then a number you can graph and gate deploys on. For a 28-day rolling window:

```promql
# budget consumed = (1 - realized availability) / (1 - target)
record: slo:http_availability:error_budget_consumed_28d
expr: |
  (1 - (sum_over_time(sli:http_availability:ratio_rate5m[28d])
        / count_over_time(sli:http_availability:ratio_rate5m[28d])))
  / (1 - slo:http_availability:target)
```

A value of `0.4` means you've spent 40% of the month's budget; `>= 1.0` means it's gone and the pre-agreed freeze policy kicks in. The "nines" cheat sheet from Module 01, repeated here because you'll reach for it constantly:

| SLO | Error budget | ≈ Downtime / 30 days | ≈ Downtime / year |
|-----|--------------|----------------------|-------------------|
| 99%     | 1%      | ~7.2 hours   | ~3.65 days  |
| 99.9%   | 0.1%    | ~43 minutes  | ~8.76 hours |
| 99.95%  | 0.05%   | ~22 minutes  | ~4.38 hours |
| 99.99%  | 0.01%   | ~4.3 minutes | ~52.6 minutes |

> **Rolling vs. calendar windows.** A 28-day *rolling* window means the budget refills continuously as old errors age out — good for engineering, bad for billing (there's no clean "month"). A *calendar* month window resets on the 1st, which matches SLAs but creates a cliff where a bad last-day-of-month incident can't recover before the contract reads. Most teams alert on rolling (for responsiveness) and report on calendar (for stakeholders). Pick deliberately; don't let the default library window decide for you.

---

## Burn-rate alerting — the full multi-window rule set

Module 01 made the case for burn rate over static thresholds. Here is the production-grade rule set: **multi-window, multi-burn-rate**, straight out of the Google SRE workbook, expressed against the recording rules above.

Burn rate = how fast you're spending budget relative to the rate that spends it *exactly* at window end. Burn rate 1 = on-pace; burn rate 14.4 = you'll torch a 28-day budget in 2 days.

| Severity | Burn rate | Long window | Short window | Budget burned to fire | Action |
|----------|-----------|-------------|--------------|-----------------------|--------|
| **Page**   | 14.4 | 1 hour  | 5 min   | 2% in 1h  | Wake someone up now |
| **Page**   | 6    | 6 hours | 30 min  | 5% in 6h  | Wake someone up |
| **Ticket** | 3    | 1 day   | 2 hours | 10% in 1d | Next business day |
| **Ticket** | 1    | 3 days  | 6 hours | 10% in 3d | Low-urgency investigation |

The two-window AND is the whole trick. The **long** window gives confidence (this is sustained, not a blip); the **short** window is the *reset* — once errors stop, the short window recovers in minutes and silences the alert even while the long window is still elevated. Without the short window, your page keeps screaming for an hour after you've fixed it.

```yaml
# PrometheusRule: multi-window fast + slow burn for a 99.9% SLO.
# error budget fraction = 1 - 0.999 = 0.001
groups:
  - name: slo-http-availability
    rules:
      # --- fast burn: 14.4x over 1h, confirmed by 5m ---
      - alert: ErrorBudgetBurnFast
        expr: |
          (1 - sli:http_availability:ratio_rate1h) > (14.4 * 0.001)
          and
          (1 - sli:http_availability:ratio_rate5m) > (14.4 * 0.001)
        for: 2m
        labels:
          severity: page
        annotations:
          summary: "Fast error-budget burn on {{ $labels.service }}"
          description: "Burning >14.4x budget over 1h and 5m. ~2% of 28d budget per hour."
      # --- slow burn: 6x over 6h, confirmed by 30m ---
      - alert: ErrorBudgetBurnSlow
        expr: |
          (1 - sli:http_availability:ratio_rate6h) > (6 * 0.001)
          and
          (1 - sli:http_availability:ratio_rate30m) > (6 * 0.001)
        for: 15m
        labels:
          severity: page
        annotations:
          summary: "Sustained error-budget burn on {{ $labels.service }}"
          description: "Burning >6x budget over 6h and 30m. A slow leak that will exhaust the budget."
```

> `0.001` is the one magic number here — `(1 - 0.999)`, the budget as a fraction. It appears once per threshold; everything else is named. Change the SLO in `slo:http_availability:target` and update these constants in lockstep, or better, template them so there's a single source of truth. The `{{ $labels.service }}` renders literally in this doc — in Alertmanager it expands to the firing series' service label.

You need the `rate1h`, `rate6h`, `rate30m` sibling recording rules (same shape as the `rate5m` one above, different window). Pre-computing them is not optional at scale: evaluating a raw `rate(...[6h])` per alert cycle across thousands of series is how you melt Prometheus.

### Routing: the alert is only half the job

A perfect burn-rate alert that pages the wrong person at the wrong urgency is still a bad alert. Alertmanager routes on the `severity` label you set above:

```yaml
route:
  receiver: slack-noise         # default: everything lands here
  group_by: ['service', 'alertname']
  routes:
    - matchers: [severity = page]
      receiver: pagerduty-oncall # fast+slow burn -> actually wakes someone
      group_wait: 30s
      repeat_interval: 4h
    - matchers: [severity = ticket]
      receiver: slack-tickets    # slow burns -> a channel, not a pager
```

`group_by` collapses a storm of per-pod alerts into one notification per service — the difference between one page and fifty.

---

## The Four Golden Signals, wired to Kubernetes

Latency, Traffic, Errors, Saturation. Module 01 covered the subtleties; here is where each one comes *from* in a kind/LGTM world:

```
 ┌─────────────┬────────────────────────────────┬──────────────────────────────────┐
 │  SIGNAL     │  SOURCE                         │  EXAMPLE PROMQL                   │
 ├─────────────┼────────────────────────────────┼──────────────────────────────────┤
 │  LATENCY    │ ingress / mesh / app histogram  │ histogram_quantile(0.99, ...)     │
 │  TRAFFIC    │ ingress / app counter           │ sum(rate(http_requests_total[5m]))│
 │  ERRORS     │ app counter by code             │ rate(http_requests_total{..5..})  │
 │  SATURATION │ kube-state + cAdvisor / node    │ container CPU vs request, throttle│
 └─────────────┴────────────────────────────────┴──────────────────────────────────┘
```

Saturation is the one people under-instrument, and in Kubernetes it has a specific, high-value form: **CPU throttling**. A container can be *under* its CPU limit on average and still be throttled hard in bursts, which shows up as latency the golden-signal "latency" panel sees but can't explain. The USE-style saturation query that explains it:

```promql
# fraction of CPU periods the container was throttled — the hidden latency cause
sum(rate(container_cpu_cfs_throttled_periods_total{namespace=~"dojo-.*"}[5m])) by (pod)
/
sum(rate(container_cpu_cfs_periods_total{namespace=~"dojo-.*"}[5m])) by (pod)
```

Memory saturation, the thing that precedes an OOMKill:

```promql
# working set as a fraction of the limit — climbs toward 1.0 before the kill
max(container_memory_working_set_bytes{namespace=~"dojo-.*"}) by (pod)
/
max(kube_pod_container_resource_limits{namespace=~"dojo-.*", resource="memory"}) by (pod)
```

**Alert on symptoms (latency, errors — RED), investigate with causes (saturation — USE).** Paging on high CPU is noise; high CPU is often exactly what you want. Paging on user-facing error burn is signal.

---

## Dashboards that catch outages, not ones that win demos

A dashboard is a diagnostic instrument, not a trophy wall. The layout that works, top to bottom:

```
 ┌──────────────────────────────────────────────────────────────┐
 │  ROW 1 — SLO HEALTH  (the "am I in trouble" row)               │
 │  [ availability vs target ] [ error budget remaining % ]       │
 │  [ current burn rate (1h) ] [ time-to-exhaustion estimate ]    │
 ├──────────────────────────────────────────────────────────────┤
 │  ROW 2 — RED  (symptoms: what the user feels)                  │
 │  [ traffic req/s ] [ error rate by code ] [ p50/p90/p99 ]      │
 ├──────────────────────────────────────────────────────────────┤
 │  ROW 3 — USE  (causes: why they feel it)                       │
 │  [ CPU vs request ] [ mem vs limit ] [ CPU throttling % ]      │
 │  [ restarts/OOMKills ] [ pending/unschedulable pods ]          │
 └──────────────────────────────────────────────────────────────┘
```

Rules that separate useful from decorative:

- **Top row answers one question in two seconds: am I burning budget right now?** Everything below is for the human who already knows the answer is yes and needs to find out why.
- **Every latency panel is split by outcome** (success vs 5xx). A fast-failing `500` makes an un-split latency panel look *better* mid-outage — exactly backwards.
- **Thresholds on panels match the SLO constant**, not a vibe. The p99 panel's red line is your latency SLO threshold, read from the same place the alert reads it.
- **One dashboard per service, templated by `$service`**, not one giant board. A `namespace`/`service` Grafana template variable lets one dashboard serve every workload; forty bespoke dashboards is forty things to rot.

To reach Grafana from the lab stack after `install-monitoring.sh`:

```bash
kubectl -n monitoring port-forward svc/kps-grafana 3000:80   # http://localhost:3000, admin/admin
```

The bundled `kube-prometheus-stack` ships USE-style cluster/node/pod dashboards out of the box (search "Kubernetes / Compute Resources"). Those give you Row 3 for free. Rows 1 and 2 are yours to build against your app's `http_requests_total` / `http_request_duration_seconds` — because only you know what "good" and "valid" mean for your service.

---

## Debugging SLOs & alerting

When the observability layer itself is the thing that's broken, the failure is sneaky: nothing crashes, the dashboard is green or the pager is screaming, and both can be lying. Diagnose in this order — cheapest signal first.

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| On-call ignores pages; everyone has an inbox filter for the alert | **Alert fatigue** — too many non-actionable pages (static thresholds, per-pod alerts, flapping) | Delete alerts nobody acted on; switch to multi-window burn rate; `group_by` service; demote non-urgent to tickets |
| SLO reads 100% during a known outage | **Bad SLI**: denominator counts the wrong events, or you're measuring the wrong layer (LB health check, not real traffic) | Verify what the metric actually counts; exclude synthetic/health-check traffic; measure as close to the user as possible |
| SLO reads a suspiciously round number (exactly 95%, 99%) | Histogram bucket boundary doesn't match the SLO threshold → silent rounding | Add an `le` bucket *at* the SLO latency threshold; re-derive the ratio SLI |
| Alert expression errors / returns empty in Prometheus | Metric name/label typo, or the recording rule it depends on doesn't exist yet | `Status → Rules` in Prometheus UI; test the expr in the query browser first |
| Prometheus RAM climbing, queries timing out | **High-cardinality metric** — a label with unbounded values (user_id, request_id, full URL path) | Find the offender with the cardinality queries below; drop/aggregate the label via `metric_relabel_configs` |
| Alert fires long after the incident is resolved | Single-window alert with no short-window reset | Add the short-window AND clause (the multi-window pattern) |
| `TARGETS` shows your service `DOWN`, metrics missing | **Missing metrics**: ServiceMonitor selector doesn't match, wrong port name, or `/metrics` not exposed | Check the scrape target state and ServiceMonitor label match below |

### Diagnose each — the exact commands

**Alert fatigue — measure it before you argue about it.** The data lives in Prometheus's own `ALERTS` metric. If an alert fires constantly and is never acted on, it is noise by definition:

```bash
kubectl -n monitoring port-forward svc/prometheus-operated 9090:9090
# then in the Prometheus UI (http://localhost:9090), query:
#   count_over_time(ALERTS{alertstate="firing"}[7d])   -- rank alerts by how often they fire
#   sort_desc(count by (alertname) (ALERTS{alertstate="firing"}))
```

Any alert in the top of that list that didn't correspond to a real action is a deletion candidate. The goal is not "more coverage" — it's **every page is actionable**. An alert that cries wolf trains your on-call to ignore the one real wolf.

**Missing metrics — the ServiceMonitor didn't match.** `kube-prometheus-stack` discovers scrape targets via `ServiceMonitor` objects whose `selector` must match your Service's labels *and* whose port name must match the Service's named port. A mismatch means Prometheus simply never scrapes you — silently.

```bash
# is Prometheus even trying to scrape the target?
kubectl -n monitoring port-forward svc/prometheus-operated 9090:9090
# UI: Status -> Targets  — look for your job as UP; "DroppedTargets" = selector didn't match

# does the ServiceMonitor's selector match the Service's labels?
kubectl -n dojo-slo get servicemonitor web -o jsonpath='{.spec.selector.matchLabels}'; echo
kubectl -n dojo-slo get svc web -o jsonpath='{.metadata.labels}'; echo

# does the ServiceMonitor's endpoint port name match a named Service port?
kubectl -n dojo-slo get servicemonitor web -o jsonpath='{.spec.endpoints[*].port}'; echo
kubectl -n dojo-slo get svc web -o jsonpath='{.spec.ports[*].name}'; echo
```

The port is matched by **name**, not number — `port: metrics` in the ServiceMonitor must match a Service port literally named `metrics`. This is the number-one reason a freshly deployed app shows no data.

**High-cardinality metrics — find the memory bomb.** Prometheus stores one time series per unique label-set. A single label with unbounded values (a `request_id`, `email`, raw `path`) multiplies your series count until Prometheus OOMs. Hunt it:

```bash
# top metrics by series count (via the UI query browser):
#   topk(20, count by (__name__)({__name__=~".+"}))
# for a suspect metric, which label is exploding its cardinality:
#   count(count by (le, path, code) (http_request_duration_seconds_bucket)) by (path)

# TSDB-wide view: the built-in cardinality report
# UI: Status -> TSDB Status  — "Top 10 label names by cardinality" names the culprit directly
```

The fix is `metric_relabel_configs` to drop or collapse the offending label before ingestion (e.g. rewrite `/user/12345/profile` → `/user/:id/profile`), applied at the ServiceMonitor or scrape-config level. You almost never want per-request-unique labels in Prometheus — that's what Loki/Tempo are for.

> **War story.** At SAP, a teammate added a `tenant_id` label to our ingest-latency histogram to "slice per customer." Reasonable intent. But with ~8,000 tenants × 12 histogram buckets × 3 other labels, one metric became ~300k series overnight. Prometheus memory doubled, then the pod started OOMKilling mid-scrape, which created *gaps* in the data, which made the latency SLO read artificially *good* (missing bad samples), which is how we almost shipped a regression under a green dashboard. The fix was two lines of `metric_relabel_configs` dropping `tenant_id` from that metric and keeping per-tenant breakdowns in Loki where high cardinality is free. The lesson that stuck: **a label is a promise to store a time series for every value it will ever take.** Ask "how many distinct values, forever?" before you add one — and never let the observability layer's own failure masquerade as the service being healthy.

---

## Checkpoint

You're ready to move on when you can, without looking anything up:

1. Write an availability SLI as a PromQL ratio and justify why `4xx` is excluded from the denominator but a `4xx` from your own validation bug is not.
2. Explain why a latency SLI must be a *ratio under a threshold*, not a p99, and what histogram-bucket requirement that imposes.
3. Express error-budget-consumed as a queryable number and say what a value of `1.0` triggers.
4. Write the fast-burn (14.4× over 1h+5m) alert from memory and explain exactly what the short window is for.
5. Map each of the four golden signals to its Kubernetes source, and give the CPU-throttling query that explains latency a plain CPU panel can't.
6. Lay out the three dashboard rows (SLO health → RED → USE) and state which row you page on and which you investigate with.
7. Diagnose a service showing no metrics by checking the ServiceMonitor selector and *named* port match.
8. Find a high-cardinality metric via TSDB Status and name the `metric_relabel_configs` fix — and explain how an OOMing Prometheus can make an SLO lie *green*.

➡ Next up: **Module 07 — Incident Response & Production Debugging.** The alerts you built here are going to fire for real; the next module is the muscle memory for what you do in the ninety seconds after the page.
