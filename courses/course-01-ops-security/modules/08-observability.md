# Observability: Logs, Metrics & the LGTM Stack

> **Module 08 · Course 01** — You run a 100GB+/day LGTM pipeline at work, so this module skips the "what is a metric" tour and goes where it actually gets hard: the data models that make PromQL queries cheap or ruinous, the cardinality math behind the bill, and why most "observability" setups collapse at scale into expensive log search. The goal is to reason about the three signals — logs, metrics, traces — as distinct data shapes with distinct economics.

---

## kubectl: the first five minutes of any incident

Before Grafana, there's the cluster itself. The reflexes:

```bash
kubectl -n dojo-obs logs deploy/web                  # stdout/stderr of the current container
kubectl -n dojo-obs logs <pod> --previous            # the CRASHED container's logs (pre-restart) — the #1 missed command
kubectl -n dojo-obs logs <pod> -c <container> -f     # follow a specific container in a multi-container pod
kubectl -n dojo-obs logs -l app=web --max-log-requests=10 --prefix   # aggregate across pods by label
kubectl -n dojo-obs get events --sort-by=.lastTimestamp              # cluster's own history: OOMKilled, FailedScheduling, probe fails
kubectl -n dojo-obs top pod                          # live CPU/mem per pod (needs metrics-server)
kubectl -n dojo-obs top node
```

Two things people miss:

- **`--previous` is where the truth is after a crashloop.** `kubectl logs` shows the *current* (possibly freshly-restarted) container; the error that killed the last one is only in `--previous`. If the container can't start at all, there are no logs — go to `describe` and `events`.
- **`kubectl top` reads from the `metrics.k8s.io` API**, which is served by **metrics-server**, a separate component you must install. It is a *point-in-time resampled* feed (default 15s) with **no history** — it exists to power `kubectl top` and, critically, the Horizontal Pod Autoscaler. It is **not** a monitoring system; don't try to graph from it.

```
   metrics-server  ──serves──▶  metrics.k8s.io API  ──▶  kubectl top  +  HPA
   (point-in-time, ~15s, NO history, NOT for dashboards)
```

> **Container logs are ephemeral.** `kubectl logs` reads files on the node that are rotated and deleted when the pod is evicted or the node recycles. If you want logs to survive the pod, you need a log *pipeline* (Loki/Promtail, Fluent Bit) shipping them off-node. "We'll check the logs later" fails the moment the pod is gone.

> **Gotcha — `events` are garbage-collected after ~1h by default.** The Kubernetes event TTL (`--event-ttl`, default 1 hour) means that `FailedScheduling` or `OOMKilled` event from last night is *gone* by morning standup. Events are a live debugging aid, not an audit trail — if you need the history, your log pipeline must be scraping the events stream (e.g. `kube-events-exporter` into Loki), or you're reconstructing the incident from memory.

---

## Metrics: the Prometheus data model & PromQL

A Prometheus metric is a **name + a set of key/value labels → a float sampled over time**:

```
http_requests_total{method="POST", path="/checkout", status="500"}  →  42318
└──────┬──────┘ └────────────────────┬────────────────────────┘      └─┬─┘
   metric name              labels (dimensions)                       value @ timestamp
```

Each **unique combination of name + labels is one time series.** That sentence is the whole cost model — hold onto it, we return to it. The four metric types:

| Type | What it is | Example |
|------|-----------|---------|
| **Counter** | Monotonically increasing; only goes up (or resets to 0 on restart) | `http_requests_total`, `errors_total` |
| **Gauge** | A value that goes up and down | `memory_bytes`, `queue_depth`, `temperature` |
| **Histogram** | Pre-bucketed observations → `_bucket`, `_sum`, `_count` | `request_duration_seconds` |
| **Summary** | Client-side quantiles (can't be aggregated across instances) | legacy latency reporting |

Prometheus **pulls** (scrapes) `/metrics` endpoints on an interval — same pull philosophy as GitOps. PromQL operates on these series:

```promql
# per-second request rate over 5m — rate() handles counter resets for you
rate(http_requests_total[5m])

# error ratio (the SLI for availability), summed across instances
sum(rate(http_requests_total{status=~"5.."}[5m]))
  /
sum(rate(http_requests_total[5m]))

# p99 latency from a histogram, per path
histogram_quantile(0.99,
  sum by (le, path) (rate(request_duration_seconds_bucket[5m])))

# memory headroom per pod
sum by (pod) (container_memory_working_set_bytes)
  / sum by (pod) (kube_pod_container_resource_limits{resource="memory"})
```

Things that separate competent from expert PromQL:

- **`rate()` only on counters, over a range `[5m]`.** It computes per-second average and transparently corrects counter resets (a pod restart dropping the counter to 0 doesn't produce a negative spike). Use `irate()` only for fast-moving graphs; it uses the last two samples and is noisy.
- **`histogram_quantile` needs `le` kept in the `by` clause** — the quantile is computed *from the buckets*, so you must `sum by (le, ...)` before applying it. Forget `le` and you get nonsense.
- **You cannot average percentiles.** The p99 of two instances is not the average of their p99s. Aggregate the *buckets* (histograms are additive), then compute the quantile — that's why histograms beat summaries for anything you aggregate.
- **Mind the range vs. scrape interval.** `rate(...[5m])` needs at least *two* samples inside the window to compute anything; with a 60s scrape interval a `[1m]` range often sees one sample and returns empty. Rule of thumb: the range should be at least 4× the scrape interval. A dashboard panel that's blank at the right edge but fine in history is almost always this — the most recent window hasn't accumulated enough samples yet.

---

## Grafana & the LGTM stack — one pane, three signals

Grafana is the query/visualization layer; it holds no data itself, it queries datasources. **LGTM** is Grafana Labs' stack where each letter is the store for one signal shape:

```
           ┌──────────────────────────── Grafana ────────────────────────────┐
           │           (dashboards, Explore, alerting — the single pane)      │
           └───────┬───────────────┬───────────────┬──────────────────────────┘
                   │               │               │
             ┌─────▼────┐    ┌──────▼─────┐   ┌─────▼─────┐
             │   Loki   │    │   Mimir    │   │   Tempo   │
             │   LOGS   │    │  METRICS   │   │  TRACES   │
             └──────────┘    └────────────┘   └───────────┘
             label-indexed    Prometheus-      trace/span IDs,
             log lines        compatible TSDB,  exemplar-linked
             (cheap: index     horizontally     from metrics/logs
              labels, not      scalable, multi-
              full text)       tenant, long
                               retention
```

| Letter | Component | Signal | Role |
|--------|-----------|--------|------|
| **L** | **Loki** | Logs | "Prometheus for logs" — indexes **labels**, not full text; stores compressed chunks in object storage. Cheap because it doesn't build a full-text index |
| **G** | **Grafana** | all | Visualization, Explore, and unified alerting across the other three |
| **T** | **Tempo** | Traces | Distributed tracing backend; stores spans by trace ID in object storage, no index needed — you pivot *into* it from a log or metric exemplar |
| **M** | **Mimir** | Metrics | Horizontally scalable, multi-tenant, long-retention Prometheus-compatible TSDB — where metrics go when a single Prometheus can't hold them |

The architectural insight that makes LGTM coherent: **all three backends share the same label vocabulary and dump chunks into cheap object storage (S3/GCS) instead of a full-text index.** That's how you correlate — a high-latency *metric* carries an **exemplar** (a trace ID), which you click to jump to the *trace* in Tempo, whose spans link to the *logs* in Loki for that request, all filtered by the same `{namespace, pod}` labels. One pane, three signals, one join key.

> **Loki's trap is the inverse of Prometheus'.** Loki is cheap *because* it doesn't index log content — so a query that filters only by label is fast, but `|= "user_id=12345"` scans the raw chunks. At 100GB/day, label your streams well (`{namespace, app, level}`) and push structured fields you filter on into labels sparingly — every label value is a separate stream, and too many streams is Loki's version of cardinality explosion.

---

## The four golden signals & SLOs

From the Google SRE book — the four things to measure for any user-facing service, in priority order:

| Signal | Question | Typical metric |
|--------|----------|----------------|
| **Latency** | How long do requests take? (split success vs. error latency!) | `histogram_quantile(0.99, ...)` |
| **Traffic** | How much demand? | `sum(rate(http_requests_total[5m]))` |
| **Errors** | What fraction fail? | `rate(...{status=~"5.."}[5m]) / rate(...)` |
| **Saturation** | How full is the system? | CPU/mem/queue vs. capacity |

Latency has a subtlety: **measure failed-request latency separately.** A fast 500 is not success — if you average error and success latency together, a flood of fast errors makes your latency graph look *better* while the service burns.

An **SLO** turns signals into a promise and a budget:

```
SLI   = the measurement            e.g. "fraction of requests served <300ms AND 2xx/3xx"
SLO   = the target over a window   e.g. "99.9% of requests, rolling 28 days"
Error budget = 100% − SLO          e.g. 0.1%  →  ~43 minutes of failure / 30 days
```

```promql
# 28-day availability SLI (success ratio)
sum(rate(http_requests_total{status!~"5.."}[28d]))
  /
sum(rate(http_requests_total[28d]))
```

The error budget is the point: it's a **shared currency between dev and ops.** Budget remaining → ship features freely. Budget exhausted → the policy says stop feature work and spend the next cycle on reliability. You alert on **burn rate** (how fast you're consuming the budget), not on raw error rate — a multi-window burn-rate alert (fast burn over 1h *and* 5m) pages for genuine budget threats and stays quiet for a brief blip that the 28-day budget easily absorbs. That's how you escape alert fatigue.

---

## Structured logging at 100GB+/day — cardinality is the bill

At your volume, the enemy is **cardinality**: the number of distinct time series (metrics) or log streams (Loki). Cost and memory scale with *series count*, not request count, and it compounds multiplicatively:

```
   one metric  http_requests_total
     × method   (5 values:  GET POST PUT DELETE PATCH)
     × status   (~8 values)
     × path     (BOUNDED template:  20 route patterns)        →  5 × 8 × 20  = 800 series ✓
     × path     (UNBOUNDED raw URL:  /user/8831/order/44021)  →  5 × 8 × ∞   = explosion ✗
     × user_id  (1,000,000 users)                             →  millions of series — do NOT ✗
```

The rules that keep the bill finite:

- **Never put unbounded values in metric labels.** `user_id`, `request_id`, raw URL path, email, full timestamp, container ID — each distinct value is a *permanent* new series that Prometheus holds in memory. Those dimensions belong in **logs/traces** (high-cardinality is cheap there), never in metric labels. This single mistake is the most common cause of a Prometheus OOM.
- **Templatize paths before they become labels.** `/user/{id}/order/{id}`, not the raw URL. Do it at instrumentation time.
- **Structured logs (JSON), not string soup.** Emit `{"level":"error","trace_id":"...","user_id":"...","latency_ms":312}` so queries filter on fields instead of regex-scraping text. Put the join keys (`trace_id`) in the log body; keep Loki *stream labels* low-cardinality (`namespace`, `app`, `level`) — a label per `user_id` explodes Loki exactly like a metric label explodes Prometheus.
- **Sample the high-volume, low-information signal.** You don't need every one of a million identical 200-OK access logs or every trace. Tail-based sampling (keep 100% of errors and slow traces, 1% of fast successes) and log-level sampling cut 100GB/day to something queryable without losing the signal that matters. The errors are never the expensive part — the successes are.
- **Pick the right signal for the question.** "What's my p99 and error rate?" → a metric (cheap, pre-aggregated). "Why did *this specific* request fail?" → a trace + its logs (high-cardinality, pulled on demand). Using log search to compute rates you could have gotten from a counter is how observability bills reach six figures.

> **The economics in one line:** metrics are cheap to aggregate and expensive to make high-cardinality; logs/traces are cheap to make high-cardinality and expensive to aggregate. Put each question on the signal whose cost model fits it, and your 100GB/day stays affordable. Put them on the wrong one and you either OOM Prometheus or pay to grep petabytes.

---

## Debugging observability

The cruel irony of observability is that the system meant to explain every other outage is itself a distributed system that breaks silently — a blank panel looks identical whether the service is healthy, the scrape is failing, or the query is wrong. Triage by asking *which layer is lying*: the pod, the metrics API, the scrape, or the query.

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `kubectl top` → `error: Metrics API not available` | metrics-server not installed, or stuck `NotReady` on kind (self-signed kubelet certs) | Install + patch: `bash labs/bootstrap/install-metrics-server.sh` (adds `--kubelet-insecure-tls`); wait ~30s |
| `kubectl logs` → "previous terminated container not found" | Container never restarted (no previous), or the node recycled the log | Confirm with `kubectl describe pod` → `Last State` / `Restart Count`; if 0 there's genuinely no previous |
| `kubectl logs` empty but pod `CrashLoopBackOff` | Container dies before writing stdout, or logs to a file not stdout | `kubectl describe pod` → exit code & reason; `--previous`; check the entrypoint logs to a file |
| Dashboard panel blank at the right edge, fine in history | `rate()` range too short for the scrape interval (needs ≥2 samples) | Widen the range (`[5m]`+), or check scrape is still happening (see below) |
| A metric **disappeared** entirely | Target down/unscraped, relabeling dropped it, label renamed, or recording rule stopped | Check `up{job="..."}`; inspect Prometheus **Targets** page for scrape errors |
| Prometheus RAM climbing, then **OOMKilled** | Cardinality explosion — an unbounded label (user_id, raw path, pod UID) crept in | Find the offender with `topk` on series count (below); drop the label at instrumentation |
| p99 panel shows absurd/flat values | `le` dropped from the `by` clause, or buckets don't cover the real latency range | Keep `le`; verify `_bucket` boundaries actually span your latencies |
| Loki query times out / "too many streams" | High-cardinality stream label (per-user, per-request-id), or a content filter scanning raw chunks | Reduce stream labels; move the filter to a label selector; narrow the time range |

Diagnose each — the commands, cluster-first then query-layer:

```bash
# metrics-server: is it even Ready? (classic kind failure: self-signed kubelet certs)
kubectl -n kube-system get deploy metrics-server
kubectl -n kube-system logs deploy/metrics-server | grep -i -E 'tls|x509|error'
# the fix is baked into the lab helper (it adds --kubelet-insecure-tls and waits):
bash labs/bootstrap/install-metrics-server.sh
kubectl -n kube-system rollout status deploy/metrics-server --timeout=120s

# crashloop truth: state, exit code, restart count, and the pre-restart logs
kubectl -n dojo-obs describe pod <pod> | sed -n '/Last State/,/Ready/p'
kubectl -n dojo-obs logs <pod> --previous

# is the scrape actually happening? `up` is 1 when the last scrape succeeded, 0 when it failed
#   (run these in Grafana Explore / the Prometheus UI, not kubectl)
#   up{namespace="dojo-obs"}
#   scrape_samples_scraped{job="web"}           # 0 means the endpoint returned nothing

# find the cardinality bomb BEFORE it OOMs you (Prometheus UI / Explore):
#   topk(10, count by (__name__)({__name__=~".+"}))      # which metrics have the most series
#   count(count by (user_id) (http_requests_total))      # how many distinct values of a suspect label
#   prometheus_tsdb_head_series                            # total in-memory series — your memory driver

# node-level: on kind the "nodes" are containers — peek at kubelet from inside
kind get nodes --name dojo
docker exec dojo-control-plane crictl ps | head        # containers the kubelet sees
docker exec dojo-control-plane journalctl -u kubelet --no-pager | tail -40
```

### A PromQL troubleshooting example

Symptom: your error-ratio panel reads a flat **0** during an incident you *know* is on fire. Walk the query inward:

```promql
# 1. The panel query. Returns nothing — but is the numerator wrong, or the whole thing?
sum(rate(http_requests_total{status=~"5.."}[5m])) / sum(rate(http_requests_total[5m]))

# 2. Strip to the numerator. Empty? Then no 5xx series match — suspicious.
sum(rate(http_requests_total{status=~"5.."}[5m]))

# 3. Drop the filter and LOOK at the actual label values. The bug reveals itself:
count by (status) (http_requests_total)
#   → status="500" exists... as status_code="500". The label is named differently than you assumed.
#   OR → status is an int "500" vs the regex "5.." expecting a string — matches, but maybe the app emits "server_error".
```

The three failure classes this covers: **(a)** the label name is wrong (`status` vs `status_code`) → the filter matches nothing; **(b)** the label *value* vocabulary isn't what you assumed (`server_error` not `500`) → regex misses; **(c)** the denominator is non-zero but the numerator is genuinely zero → the query is correct and you're looking at the wrong service. Always `count by (<label>)` the raw metric to see reality before trusting a filter you wrote from memory.

> **War story.** A team shipped a "harmless" instrumentation PR: add a `path` label to `http_requests_total` for per-endpoint dashboards. Code review waved it through — one label, what's the harm. The catch: the handler labeled requests with `r.URL.Path` (the *raw* path), not the route template. Every `/user/8831/order/44021` was a brand-new series. Prometheus `head_series` climbed from 400k to 11M over an afternoon; the pod hit its memory limit, `OOMKilled`, restarted, and *lost its entire in-memory head block* — a two-hour hole in every dashboard, right when a separate latency incident needed those dashboards. The tell was in `topk(10, count by (__name__)({__name__=~".+"}))`: `http_requests_total` alone held 90% of all series. Fix was a one-liner — `mux.Vars` route template instead of raw path — plus a standing alert on `prometheus_tsdb_head_series > 1e6` so the next explosion pages *before* the OOM, not after. The lesson from Module 08 made concrete: an unbounded label is a time bomb, and the blast radius is every dashboard, not just the new one.

---

## Checkpoint

You're ready to move on when you can, without looking anything up:

1. Explain why `kubectl logs --previous` matters after a crashloop, and why `kubectl top` is not a monitoring system (what serves it, and what it lacks).
2. Define a Prometheus time series precisely, and explain why `rate()` applies only to counters over a range and how it handles resets.
3. Write the PromQL for a 5xx error ratio and a p99 latency from a histogram — and explain why you must keep `le` in the `by` clause and why you can't average percentiles.
4. Map each letter of LGTM to its signal and store, and describe the exemplar/label path that lets you pivot from a slow metric to the trace to the logs.
5. Give a concrete cardinality-explosion example (what label kills you) and state where high-cardinality identifiers belong instead; then explain error budgets and why you alert on burn rate.
6. Say why metrics-server sits `NotReady` on a kind cluster and the exact flag that fixes it (and which lab helper bakes it in).
7. Given a blank error-ratio panel, list the three query-layer failure classes and the one `count by (...)` reflex that surfaces all three.
8. Name the single metric (`prometheus_tsdb_head_series`) and the `topk(... count by (__name__) ...)` query you'd use to catch a cardinality bomb before it OOMs Prometheus.

➡ That's Course 01. You've gone from a throwaway `kind` cluster through resilient Deployments, Services, config, secrets, RBAC, GitOps, and observability — operating and attacking each one. Next course: production SRE — scaling, autoscaling, and failure injection.
