# Latency & Percentiles

> **Module 03 · Course 29** — "Average response time is 50 ms" is one of the most dangerous sentences in systems engineering. It conceals the distribution, hides the tail, and misleads capacity planning. This module replaces the average with the mental model you actually need.

---

## Why Averages Lie

The mean of a latency distribution is dominated by the bulk of requests. A handful of slow requests — exactly the ones that break SLAs, time out client connections, and generate user complaints — get mathematically diluted.

Concrete example. 100 requests. 90 complete in 10 ms. 9 complete in 50 ms. 1 completes in 4000 ms.

```
Mean = (90×10 + 9×50 + 1×4000) / 100 = (900 + 450 + 4000) / 100 = 53.5 ms
```

"Average latency: 54 ms" — that one 4-second request is completely invisible. 1% of your users just had a 4-second experience and your dashboard says "looking good."

The fix is to describe the *distribution* using percentiles. Every latency discussion at SDE-2 level and above uses percentiles.

---

## p50 / p95 / p99 / p99.9

A percentile answers: "what is the maximum latency experienced by the Xth-percentile user?"

| Metric | Meaning | "1 in N users is at or below this" |
|--------|---------|-----------------------------------|
| p50 (median) | Half of requests are faster than this | 1 in 2 |
| p95 | 95% of requests are faster than this | 1 in 20 |
| p99 | 99% of requests are faster than this | 1 in 100 |
| p99.9 ("three nines") | 99.9% of requests are faster | 1 in 1000 |

For a high-traffic service handling 1000 req/s, p99.9 events happen once per second. If p99.9 is 2 seconds, you have one 2-second response every second, 24/7.

**Which percentile to track?**

- **SLO commitments:** agree on a percentile with your stakeholders. "p99 < 200 ms" is a real SLO. "Average < 50 ms" is not.
- **User-facing APIs:** p99 is standard. p99.9 for payment or authentication flows.
- **Internal microservices:** p99 or p99.9, depending on fan-out (see below).
- **Background jobs:** p95 or p99 depending on customer visibility.

**Don't track the maximum.** `max` is a single data point, not a stable statistic. It will spike to your worst-ever outlier and stay there. Use p99.9 instead — it's the worst 0.1%, not a single outlier.

---

## Tail Latency and Fan-Out Amplification

This is where percentiles become existential for microservice architectures.

**Single service:** if one service has p99 of 100 ms, 1 in 100 requests is slow.

**Fan-out:** a parent service calls N downstream services in parallel, waits for all N, then responds. What is the effective latency?

If each downstream service has independent p99 of 100 ms, the probability that *all* N are fast is:

```
P(all N are below p99) = 0.99^N
```

| N downstream calls | P(all fast) | Effective "slow" rate |
|-------------------|------------|----------------------|
| 1 | 99.0% | 1% |
| 5 | 95.1% | 4.9% |
| 10 | 90.4% | 9.6% |
| 50 | 60.5% | 39.5% |
| 100 | 36.6% | 63.4% |

At 50 downstream calls, nearly **40% of parent requests** will have at least one slow downstream — even though each individual service has a "good" p99.

**Practical consequence:** in a microservices system, tail latency compounds. Every service hop narrows your margin. This is why services at Amazon and Google operate at p99.9 targets even for internal calls — the fan-out math demands it.

**Mitigation strategies:**
- **Hedged requests:** send the same request to two replicas simultaneously; use the first response, cancel the other. Cuts tail latency at the cost of ~2× load.
- **Timeout budgets:** each service has a total time budget for its downstream calls. Enforce it with deadlines/contexts, not per-call timeouts.
- **Reduce fan-out:** aggregate multiple downstream calls into one wherever the API allows. N=1 has no amplification.

---

## Histograms vs Summaries

This distinction matters when choosing between Prometheus metric types.

### Histogram

A histogram pre-defines bucket boundaries and counts how many observations fall in each bucket. Example buckets: `[1ms, 5ms, 10ms, 25ms, 50ms, 100ms, 250ms, 500ms, 1s, 5s]`.

**Properties:**
- Stored on the **server side** (Prometheus scrapes cumulative bucket counts).
- Percentiles are **calculated at query time** in PromQL using `histogram_quantile()`.
- Can be **aggregated** across instances — sum the bucket counts, then compute the quantile.
- Bucket boundaries are fixed at instrument time. If p99 exceeds your largest bucket, it clips.

```promql
# p99 latency for a histogram metric
histogram_quantile(0.99, rate(http_request_duration_seconds_bucket[5m]))
```

### Summary

A summary pre-computes configured quantiles (e.g., 0.5, 0.95, 0.99) on the **client side** (in the application process) over a sliding time window.

**Properties:**
- Percentiles are **pre-computed** — no query-time calculation.
- Cannot be **aggregated** across instances — you cannot average p99 across 10 pods.
- Accurate per-instance percentile with no bucket boundaries to choose.

**Rule:** if you have multiple instances of a service, use a **histogram**. Summaries cannot be meaningfully aggregated. The aggregation limitation makes summaries mostly useless for horizontally scaled services.

```python
# prometheus-client Python — histogram preferred for multi-instance services
from prometheus_client import Histogram

REQUEST_LATENCY = Histogram(
    'http_request_duration_seconds',
    'HTTP request latency',
    buckets=[.005, .01, .025, .05, .1, .25, .5, 1.0, 2.5, 5.0]
)

with REQUEST_LATENCY.time():
    result = do_request()
```

---

## Coordinated Omission (reprise)

Covered in Module 02, but it deserves mention here in the context of reading latency distributions.

When a load generator uses a closed workload model, a slow response suppresses subsequent requests. The latency histogram shows a tight, optimistic distribution. The real distribution — what users experience — is wider and has a fatter tail.

**How to detect it in a histogram:** look for a suspicious "hard wall" at the response time of slow requests. If the histogram shows 97% of requests at < 20 ms and 3% at exactly 500 ms with nothing in between, the generator may be holding back requests during slow responses rather than measuring them correctly.

**HDR Histogram** (High Dynamic Range Histogram) is the data structure that makes open-model load generators correct. It tracks the full distribution with precision across a wide dynamic range (nanoseconds to minutes) without pre-defined buckets. k6 and wrk2 use it.

---

## Latency Budgets

A latency budget is how you enforce an end-to-end SLO across a chain of services.

**Approach:**
1. Define the user-facing SLO: "p99 < 300 ms."
2. Identify the call chain: API Gateway → Auth → Business Logic → Database.
3. Allocate budget across each hop. The allocations must sum to the total budget with margin.

Example allocation for a 300 ms p99 budget:

| Component | Budget |
|-----------|--------|
| API Gateway overhead | 5 ms |
| Auth service | 20 ms |
| Business logic (compute) | 30 ms |
| Database query | 200 ms |
| Network round-trips | 20 ms |
| **Total** | **275 ms** (25 ms margin) |

Each team owns a budget. If Auth is taking 80 ms, that's not the database team's problem — it's an Auth team incident. Budgets make ownership clear and prevent "the whole system is slow" finger-pointing.

**In practice:** set per-service timeout deadlines that enforce the budget. In gRPC, use deadline propagation. In HTTP, set per-call timeouts that add up to slightly less than the end-to-end budget.

---

## Debugging Latency & Percentiles

### Symptom → Cause → Fix

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| "Average looks fine but users complain" | Average conceals the tail; p99 or p99.9 is high | Switch dashboards to p95/p99; add alerting on p99 |
| p99 suddenly spikes but p50 is stable | GC pause, lock contention, infrequent expensive query, periodic batch job interfering | Check GC logs; look for lock wait histograms; look for cron jobs running at the spike interval |
| p99 is 10× p50 consistently | Bimodal distribution: two distinct code paths (cache hit vs miss, fast path vs slow path) | Separate the two paths; label metrics by cache hit/miss; investigate the slow path independently |
| End-to-end p99 high but all individual services look fine | Fan-out amplification: multiple slow tails compound | Instrument the end-to-end trace; count downstream calls per request; apply hedged requests or reduce fan-out |
| Latency histogram shows a "cliff" at exactly one value | Coordinated omission in the load generator | Switch to open workload model; use HDR histogram |
| p99 improves after deploy but SLO is still breached | Wrong percentile in the SLO; budget not allocated correctly | Re-derive p99.9; rebuild latency budget from trace data |

### "avg looks fine but users complain" — the canonical incident

> **War story.** A Python FastAPI service at a side project reported average response time of 38 ms on all dashboards — well within the 100 ms SLA. Engineers signed off on the deploy. Within an hour, Slack was full of "the app is slow" reports. Investigation: the dashboard only tracked the mean. A `histogram_quantile(0.99, ...)` query showed p99 at 1.4 seconds — a Redis cache miss on ~1% of requests was triggering a full database re-query that no one had profiled. The mean was 38 ms because 99% of requests were fast. The p99 was 1.4 seconds because the slow path wasn't being measured. Fix: set alerting on p99, not mean. Add a separate Histogram bucket for cache-miss requests to isolate the slow path. The incident would never have reached production if the SLO had been stated as "p99 < 200 ms" and enforced in the CI load test.

### Tail amplification across microservices — the math in the wild

> At SAP on the LGTM pipeline, a log ingestion path fanned out to five downstream validators and a metadata enrichment service. Each service had p99 of 80 ms — perfectly acceptable in isolation. But the ingestor was occasionally taking 900 ms end-to-end, and the on-call team was chasing phantom bugs. Applying the fan-out math: P(all 6 services fast) = 0.99^6 = 94.1%, meaning 5.9% of ingest calls would wait on at least one slow service. That matched the actual p95 (~90 ms) and p99 (~800 ms) discrepancy. The fix was: (a) set per-call timeout budgets that enforced the 300 ms end-to-end SLO, and (b) make the metadata enrichment call async and non-blocking. p99 dropped from 800 ms to 120 ms. The services hadn't changed — the call structure had.

---

## Checkpoint

You're ready for the next module when you can, without looking anything up:

1. Compute p50, p99, and the mean for a distribution of: 100 requests where 98 take 10 ms, 1 takes 100 ms, 1 takes 5000 ms. State why the mean is misleading here.
2. Explain fan-out amplification: if a service calls 10 downstream services with p99 100 ms each, what is the probability the parent request is slow?
3. State the fundamental difference between a Prometheus Histogram and a Summary, and explain why a Summary cannot be aggregated across pods.
4. Define a latency budget and sketch one for a 3-service chain with a 200 ms end-to-end p99 SLO.
5. Explain coordinated omission in 2 sentences and name a load generator that correctly avoids it.
6. Describe the alerting and dashboard changes you would make to a service currently tracked only by mean latency.

➡ Next up: **Profiling** — finding the actual hotspot before you optimize. CPU vs wall vs memory profiling, flamegraphs, py-spy, and GC pressure.
