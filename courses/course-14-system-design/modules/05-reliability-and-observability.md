# Reliability & Observability

> **Module 05 · Course 14** — An unreliable system is not a fast system with occasional downtime — it's a system whose users have learned not to trust it. Reliability is a design property, not an ops afterthought. This module covers the contracts (SLOs, error budgets), the load-control primitives (rate limiting, circuit breakers, bulkheads), the failure modes that kill distributed systems (retry storms, cascading failure), and the measurement model (golden signals) that tells you something is wrong before your SLA is breached.

---

## SLOs and Error Budgets

### The Three-Level Hierarchy

- **SLI (Service Level Indicator)**: a measured ratio. Example: `successful_requests / total_requests` over a rolling 28-day window.
- **SLO (Service Level Objective)**: the target for the SLI. Example: SLI ≥ 99.9% (a 28-day error budget of ~40 minutes).
- **SLA (Service Level Agreement)**: a contractual commitment with a financial penalty for breach. The SLO is your internal target; the SLA is what you signed with the customer. SLOs should be tighter than SLAs — you want to burn your internal budget before you breach the contract.

### Error Budget Math

```
99.9% SLO over 28 days:
  Total minutes = 28 × 24 × 60 = 40,320
  Error budget   = (1 - 0.999) × 40,320 = 40.32 minutes of allowed failures

99.5% SLO over 28 days:
  Error budget   = 0.005 × 40,320 = 201.6 minutes
```

The error budget is not just a number — it's a **deployment velocity dial**. If you've burned 80% of your budget with 10 days left, you stop shipping new features and focus on stability. If you have budget to spare, you ship faster. This is the SRE bargain: reliability is not a hard rule, it's an economic decision.

### Burn Rate Alerts

A flat alert on SLO breach fires at the last minute. Burn rate catches it early.

```
burn_rate = (error_rate_observed) / (1 - SLO_target)
```

If your SLO is 99.9% and you're seeing 1% errors, your burn rate is:
`0.01 / 0.001 = 10x` — you're consuming the budget 10 times faster than allowed.

Standard two-window alert:
- **Fast burn**: 1-hour window, burn rate > 14.4 → page immediately (6x budget consumed in 1h projects to full exhaustion in 5 days if unchecked — but high-precision; short window can have noise).
- **Slow burn**: 6-hour window, burn rate > 6 → ticket/warning (catching sustained degradation, not a spike).

The numbers come from Google's SRE workbook. Tune them for your SLO percentage and acceptable detection latency.

---

## Rate Limiting

Rate limiting is **controlled admission**: you allow requests up to a threshold and reject (or delay) the rest with `429 Too Many Requests`.

### Algorithms

| Algorithm | How it works | Burst behavior | Best for |
|---|---|---|---|
| Token bucket | Bucket refills at a fixed rate; each request consumes a token | Allows bursts up to bucket size | APIs with natural burst — the right default |
| Leaky bucket | Requests queue; processed at a fixed outflow rate | Smooths traffic to a constant rate | Upstream that cannot handle bursts |
| Fixed window counter | Count requests in the current minute; reset at minute boundary | Allows 2× limit across a window boundary | Simple, but the boundary-crossing attack is real |
| Sliding window log | Log each request timestamp; count those within the last N seconds | No boundary attack; high memory | Low-volume, precision matters |
| Sliding window counter | Weighted blend of previous and current fixed window counts | Approximation; O(1) memory | High-volume, acceptable approximation |

For most APIs: **token bucket** at the gateway per client ID. Per-user limits in Redis:

```
-- pseudo-lua in Redis (atomic via EVAL)
local tokens = redis.call('GET', key)
if tokens == nil then tokens = CAPACITY end
if tokens > 0 then
    redis.call('DECR', key)
    redis.call('EXPIRE', key, WINDOW_SECONDS)
    return 1  -- allowed
else
    return 0  -- rejected
end
```

### Where to Enforce

In order from cheapest to most precise:

1. **CDN / edge** — coarse rate limiting by IP; cheapest; doesn't protect internal services.
2. **API gateway** — per-client-ID; right layer for external APIs.
3. **Service-level** — per-endpoint or per-user; enforces business rules (e.g., "a user can submit 5 reports per hour").
4. **Database** — a last resort; the DB is the bottleneck, not the guardian.

Enforce at the earliest boundary that has the right identity context.

---

## Circuit Breakers

A circuit breaker is a **stateful proxy** around a remote dependency. It tracks failures and, when failures exceed a threshold, **opens** the circuit — fast-failing all requests without even attempting the downstream call. This prevents one slow dependency from exhausting your thread pool and failing your entire service.

```
CLOSED         OPEN            HALF-OPEN
(normal) ──► (broken) ──► (probe) ──► CLOSED (recovered)
                              └──► OPEN (still broken)

State transitions:
  CLOSED: pass requests through; count failures
  CLOSED → OPEN: failure rate > threshold in rolling window (e.g., 50% of last 20 calls)
  OPEN: fail fast immediately; start a timeout timer
  OPEN → HALF-OPEN: timer expires; allow one probe request
  HALF-OPEN → CLOSED: probe succeeds
  HALF-OPEN → OPEN: probe fails; restart timer
```

### What to Return When Open

Don't just return a 500. Options in preference order:
1. **Cached stale data** — acceptable for reads (a feed, a product catalog).
2. **Graceful degradation** — omit the feature, proceed with defaults (no personalization, show a generic response).
3. **503 with Retry-After** — tell the client when to try again.

Never silently return empty data when you should be returning an error — that's worse than a 503 because the caller can't distinguish "no results" from "circuit is open."

### Implementation Notes

Libraries: Resilience4j (JVM), `opossum` (Node.js), `gobreaker` (Go), `circuitbreaker` (Python). Do not hand-roll; the half-open transition timing is subtle to get right.

Per-dependency circuit: one circuit per downstream dependency per service. Sharing a circuit across dependencies means a failure in Service B opens the circuit for Service C.

---

## Bulkheads

A bulkhead is a **resource partition** that prevents one component from consuming resources needed by another — named after the watertight compartments in a ship's hull.

### Thread Pool Bulkhead

```
Service A:
  ┌─── Thread pool for Database calls  (size 20) ─────┐
  ├─── Thread pool for External API calls (size 10) ───┤
  └─── Thread pool for async tasks (size 30) ──────────┘

Without bulkhead:
  Single shared thread pool (size 50)
  → slow DB query fills all 50 threads
  → external API calls queue, timeout
  → health check times out → load balancer removes instance
  → cascading failure
```

### Connection Pool Bulkhead

Separate connection pools per downstream service. If Service B is slow and holds connections, it exhausts its pool only — Service C's pool is untouched.

### Semaphore Bulkhead

For CPU-bound or in-memory work: limit concurrent executions with a semaphore. Requests that cannot acquire the semaphore get a 503 immediately rather than queuing indefinitely.

Bulkheads and circuit breakers are complementary: the circuit breaker detects that a dependency is failing and stops calling it; the bulkhead limits how much damage the failing dependency can do while the circuit is still closed.

---

## Graceful Degradation

Graceful degradation is the practice of **returning reduced functionality instead of total failure** when a dependency is unavailable.

### Strategies

| Strategy | Example | When to use |
|---|---|---|
| Cached stale data | Serve last-known product inventory | Read paths; data can be slightly stale |
| Feature flag / kill switch | Disable recommendation engine if it's down | Non-critical features with fallback |
| Default / empty response | Return empty personalization; show generic content | Feature adds value but absence is tolerable |
| Partial result | Return items 1–20 from DB cache; skip items needing slow service | Paged reads where partial is better than nothing |
| Queue for later | Accept a write; defer the side effect | Writes where eventual consistency is acceptable |

### Kill Switches

A kill switch is a feature flag that is **off by default and only flipped during incidents** to shed load from a non-critical subsystem. Every system with more than ~5 downstream dependencies should have kill switches for the ones that are not on the critical path for a successful response. They're operated by a human on call — the circuit breaker is automated; the kill switch is deliberate.

---

## Multi-Region & Failover

### Active-Passive

One region handles all traffic; the passive region is warm and ready. On failure, DNS or a load balancer points at the passive region.

- **RTO** (Recovery Time Objective): how long until you're serving again — dominated by failover detection + DNS TTL propagation (typically 60–300s with low TTLs).
- **RPO** (Recovery Point Objective): how much data you can lose — equals the replication lag at the moment of failure.

Active-passive is simpler to operate but wastes capacity in the passive region and introduces a detectable RTO.

### Active-Active

Both regions serve traffic; writes are replicated bidirectionally. Globally distributed reads are fast. The hard problem: **conflicting writes** to the same record from two regions simultaneously. Resolutions:

- Last-write-wins (CRDTs, Dynamo-style): works for counters and sets; data loss on conflicts.
- Single-region writes (sticky routing by user/tenant): no conflicts; adds latency for routed writes.
- Conflict detection + merge: application-defined merge logic; complex.

### Data Replication Lag

Replication is asynchronous. A user who writes in region A and immediately reads in region B may see stale data. Options:

- **Read your own writes**: route reads for a user to the region they wrote to (sticky session or a version token).
- **Causal consistency**: pass a replication watermark as a header; the read replica waits until it has applied up to that watermark before serving.
- **Accept stale reads**: works for many read paths (a social feed, a product catalog) where eventual consistency is fine.

---

## The Golden Signals

From Google's Site Reliability Engineering book: **latency, traffic, errors, saturation**. Instrument every service on all four before adding any custom metrics.

| Signal | What to measure | Alert on |
|---|---|---|
| **Latency** | p50, p95, p99 of response time (not mean — mean hides outliers) | p99 > SLO threshold; p50/p99 divergence indicates a slow cohort |
| **Traffic** | Requests per second (RPS) by endpoint, method, status class | Sudden drop (traffic stopped flowing — upstream failure) or spike (load test, abuse) |
| **Errors** | 5xx rate; also 4xx rate for auth/validation signals | 5xx rate > error budget burn rate trigger; 4xx spike may indicate an upstream schema change |
| **Saturation** | CPU %, memory %, thread pool occupancy, queue depth, connection pool wait time | CPU > 80% sustained; queue depth growing; thread pool queue > 0 |

### p99 vs Mean

If 99% of requests finish in 10ms and 1% take 5 seconds, the mean is ~60ms — looks fine. The p99 tells the truth. For SLOs, define targets at p99 (or p99.9 for latency-sensitive paths). Mean-based SLOs are almost always lying to you.

### Distributed Tracing

Golden signals give you the symptom; traces give you the cause. A 500ms p99 spike on your API gateway: which downstream call is slow? Tracing (Jaeger, Tempo, Cloud Trace) answers that. Every RPC call should propagate a trace context header (`traceparent` W3C standard, or Jaeger's `uber-trace-id`). Sampling at 1–10% is fine for steady-state; increase to 100% during an incident.

---

## Debugging Reliability Issues

| Symptom | Likely cause | Fix |
|---|---|---|
| Latency spike with no error spike; CPU normal | Downstream dependency slow (DB, external API); thread pool waiting | Check downstream latency (golden signals on downstream); increase timeout + add circuit breaker |
| Error rate spikes when traffic spikes (throttle shape) | Thread pool or connection pool saturation; no bulkhead | Add bulkhead per dependency; right-size pool; add rate limiting upstream |
| One pod failing causes all pods to fail | Shared global state (e.g., one DB connection pool shared across all goroutines); no bulkhead | Partition resources per dependency; add circuit breaker to fast-fail |
| Retry storm: one downstream service goes slow, all upstream services peel off at the same time | No jitter on retries; retries synchronized by heartbeat or cron | Add exponential backoff with full jitter; cap retry concurrency with a semaphore |
| Cascading failure: Service A times out → Service B's thread pool fills waiting for A → Service B's callers time out | Long timeout chain; no circuit breaker | Set timeout < caller's timeout (timeout budget); circuit break at each layer |
| Traffic drops to zero suddenly; health checks pass | All instances behind LB killed by OOM, restarted, and are in startup warmup | Alert on traffic drop, not just error rate; add readiness probe with traffic-warming |
| SLO burn rate alert firing with no visible errors in APM | Long-tail latency counted as success in APM but as error in SLO (different threshold) | Align SLI measurement window and latency threshold with APM config; use histogram metrics |

> **War story.** An internal platform team I reviewed had a service that was paging on-call every night at 2am with a timeout cascade. Their checkout service called a promotions service with a 30-second timeout; the promotions service called a third-party coupon API with a 25-second timeout. When the coupon API slowed down, every checkout thread sat waiting 25s, the checkout service's thread pool (default Tomcat: 200 threads) filled in under 2 minutes, and the API gateway's health check timed out, removing the instance. Five minutes later, auto-scaling brought it back, coupon API was still slow, and the cycle repeated. The fix was a 500ms timeout on the coupon API call, a circuit breaker that fast-failed after 30% failure rate, and a cached fallback (no coupons applied) when the circuit was open. Checkout latency actually *improved* because the 500ms timeout replaced the 25s wait. Timeout budgets propagate downward, not upward.

---

## Common Mistakes

### Retry Storms

A service has 100 clients. Downstream goes slow. All 100 clients retry simultaneously at the same interval (no jitter). The downstream receives 100× the normal load from retries alone — exacerbating the outage. Always: exponential backoff with full jitter, a maximum retry count, and a circuit breaker that stops retrying entirely once the failure rate is clear.

### No Backpressure

Rate limiting and circuit breakers protect a service from external load. But if a service does not signal its saturation state to callers — no 429, no `Retry-After`, no circuit breaker fast-fail — callers will pile up connections/threads waiting, eventually timing out on their side and *masking* the actual failure signal. A 429 with `Retry-After: 5` is far more useful to a caller than a 504 after 30 seconds.

### Cascading Failure

Timeout budget mismanagement: if Service A calls Service B with a 30s timeout, and B calls C with a 30s timeout, a slow C causes A to timeout after 60s total (30s waiting for B to timeout waiting for C). The rule: **each hop's timeout must be shorter than the calling hop's timeout**, with margin for network overhead. Trace the full call graph and compute the worst-case timeout stack. Circuit breakers at each layer add a second line of defense.

---

## Checkpoint

You're ready to design reliable systems when you can do these:

1. Calculate the error budget for a 99.95% SLO over 30 days. State what burn rate 14.4 means in that context.
2. A service calls three downstream APIs: auth (critical), recommendations (non-critical), inventory (critical). Sketch the bulkhead and circuit breaker strategy.
3. What does a circuit breaker return when open? Give three options in preference order.
4. Your p99 latency is 800ms but p50 is 15ms. What does this tell you? What would you look at first?
5. Describe the cascade: slow C → what happens to B → what happens to A → what happens to the user. Where do you break the chain?
6. What is the difference between RPO and RTO? Which one is limited by replication lag?
7. A kill switch is on. List the three things you confirm before flipping it off.

➡ Next up: **Worked Designs** — apply everything from modules 01–05 to five canonical system design questions, with the exact thought process you walk through in an interview.
