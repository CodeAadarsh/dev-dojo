# Load Testing

> **Module 02 · Course 29** — Knowing what to measure is half the battle; generating the load correctly is the other half. Most "performance tests" that reach production are measuring the wrong thing because the load model is wrong. This module fixes that.

---

## Open vs Closed Workload Models

This is the most important distinction in load testing and the one most tools get wrong by default.

### Closed workload

A fixed pool of N virtual users (VUs). Each VU sends a request, waits for the response, optionally waits a think time, then sends the next request. The total number of in-flight requests is bounded by N.

```
VU1:  [req]→[wait response]→[think]→[req]→[wait response]→...
VU2:  [req]→[wait response]→[think]→[req]→[wait response]→...
...
VUN:  [req]→[wait response]→[think]→[req]→[wait response]→...
```

**Consequence:** when the server slows down, VUs spend more time waiting for responses. Fewer requests per second are sent. The measured throughput is artificially coupled to latency. A server that takes 3× longer processes only 1/3 the load — the test self-throttles, hiding the true saturation behavior.

Closed workload is appropriate when you genuinely have a fixed population of users (e.g., 50 internal employees using a tool). It is **not** appropriate for modeling internet-facing APIs.

### Open workload

Requests arrive at a fixed rate independent of response time. If the server slows down, requests pile up. Queueing depth grows. Eventually the server saturates or sheds load.

```
Arrival rate: 100 req/s  ────────────────────────────────────────►
                              ┌──────────┐
                              │  server  │──► responses
               queue builds──►          │    (slow)
                              └──────────┘
```

**Consequence:** latency and throughput decouple. You can see queueing effects, saturation, and the point where the server's response time climbs. This is how real traffic behaves — the internet doesn't slow down requests because your server is busy.

**Rule of thumb:** if users arrive independently (HTTP API, event stream, batch job queue), use an open workload model. If you have a fixed worker pool that pulls work (Celery workers, a connection pool), a closed model may be appropriate.

---

## Think Time

Think time is the pause between a user completing one interaction and starting the next. In a closed workload with zero think time, VUs hammer the server as fast as it responds — this is more like a denial-of-service test than a load test.

**Real-world think times** range from 1–5 seconds for interactive web apps to milliseconds for machine-to-machine APIs.

```python
# Locust example — realistic think time
from locust import HttpUser, task, between

class SearchUser(HttpUser):
    wait_time = between(1, 3)   # uniform [1, 3] seconds between tasks

    @task
    def search(self):
        self.client.get("/api/search?q=widget")
```

Without `wait_time`, Locust runs a closed workload with zero think time. With it, you approximate a real user session.

**Why it matters:** zero think time at 50 VUs might produce 500 req/s, flooding the server. The same 50 VUs with 3-second think time produce ~17 req/s — a completely different test, and the latter is closer to 50 real users.

---

## Ramp Profiles

A ramp is how you grow load over time. Never jump straight to peak load — the cold start obscures the shape of the throughput/latency curve.

**Staircase ramp:** increase load in steps, holding each step for long enough to reach steady state (usually 2–5 minutes at minimum). Read the latency histogram at each step.

```
req/s  │
  500  │                                 ████████
  400  │                    ████████████
  300  │         ████████████
  200  │████████
   0   └────────────────────────────────────────► time (min)
             2        4        6        8       10
```

**Ramp-up + sustained + ramp-down:** standard shape for a formal load test. Ramp-up avoids cold-start anomalies; sustained period is where you collect metrics; ramp-down confirms graceful recovery.

**Spike test:** jump to 10× normal load instantly. Tests autoscaling, backpressure, and circuit breakers. This is *not* a baseline test; it's an adversarial test.

**Soak test:** sustain moderate load for hours (overnight). Catches memory leaks, connection pool exhaustion, log disk fill, and certificate expiry. Your 5-minute benchmark won't find these.

---

## k6 and Locust — Core Concepts

You don't need to master either tool here; you need to know the concepts so you can use either correctly.

### k6 (JavaScript)

k6 uses a concept of **VUs** (virtual users) and **scenarios**. The default executor is a closed workload. To get an open workload:

```javascript
// k6 — open arrival rate (ramping-arrival-rate executor)
export const options = {
  scenarios: {
    api_load: {
      executor: 'ramping-arrival-rate',
      startRate: 10,          // 10 req/s at start
      timeUnit: '1s',
      preAllocatedVUs: 50,
      maxVUs: 200,
      stages: [
        { target: 50, duration: '2m' },   // ramp to 50 req/s
        { target: 50, duration: '5m' },   // hold
        { target: 0,  duration: '1m' },   // ramp down
      ],
    },
  },
};

export default function () {
  http.get('http://localhost:8000/api/items');
}
```

Note `ramping-arrival-rate` — this is the open model executor. The default `constant-vus` executor is closed.

### Locust (Python)

Locust is closed by default. Use `constant_throughput` or `constant_arrival_rate` wait strategies (Locust 2.x) for open workload. Locust's master-worker architecture lets you distribute load across multiple machines when a single generator saturates.

```python
from locust import HttpUser, task, constant_throughput

class ItemsUser(HttpUser):
    wait_time = constant_throughput(10)   # 10 req/s per user (open-ish model)

    @task
    def get_items(self):
        self.client.get("/api/items")
```

**When to use each:** k6 is easier for scripted open-model load; Locust is easier for complex user journeys in Python and when your test logic needs the full Python stdlib.

---

## Coordinated Omission — the Lie Inside Most Load Generators

This is the most consequential and least understood problem in load testing. It was named and popularized by Gil Tene.

**The scenario:** your load generator sends request N, waits for a response, then immediately sends request N+1. A slow response at second 30 delays the start of request N+1 to second 31. You now have a gap in arrivals. When you compute the latency of request N+1 from its *send* time to its *receive* time, it looks fast — the server responded in 10 ms. But from the perspective of a real user who would have sent that request at second 30 (and was waiting), the experienced latency is 1.01 seconds, not 10 ms.

```
Real world:                 Server slow ──► user waits
  t=30.0  user sends req N
  t=31.0  response arrives (1000ms latency)
  t=31.0  user sends req N+1  (was supposed to be t=30.0)
  t=31.01 response arrives (10ms latency)
  User experienced: req N+1 latency = 1.01s (arrived at 31.01, should have been at 30.01)

Load generator (naive):
  Reports req N+1 latency = 10ms  ← coordinated omission
```

**Impact:** your load generator reports p99 of 20 ms. Your users experience p99 of 800 ms during the same test. The generator's latency histogram is completely misleading during the exact moments that matter most (saturation, GC pauses, slow queries).

**Mitigations:**
- Use an **open workload model** where the generator does not wait before scheduling the next arrival.
- Use **HDR Histogram** (High Dynamic Range) — k6 and wrk2 use it; it tracks full latency distribution and can correct for coordinated omission.
- In Locust, be aware that the default closed model + response-time measurement has this problem. Use distributed load with enough workers that the generator is never the bottleneck, and use open arrival rate where available.

---

## Interpreting Results

A load test produces a flood of numbers. Here's what to read first:

1. **Throughput curve (req/s over time).** Did it hold stable or did it drop mid-test? A drop means the server saturated or shed load.

2. **Latency percentiles over time.** p50, p95, p99 — is p99 tracking p50 (healthy) or diverging (tail issues)?

3. **Error rate.** Any non-zero error rate during a load test is a bug unless explicitly expected (4xx for invalid input is fine; 5xx or timeouts are not).

4. **Generator-side CPU and memory.** If the generator itself hits 80% CPU, you're measuring the generator, not the server. Add more workers.

5. **Server-side USE.** Run USE analysis on the server concurrently: CPU utilization, memory saturation (swap, GC), I/O wait, network bandwidth. The load test result tells you *what*; USE tells you *why*.

---

## Debugging Load Testing

### Symptom → Cause → Fix

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Latency histogram looks great but users complain in production | Coordinated omission hiding slow responses in a closed workload model | Switch to open workload model with arrival-rate executor; use HDR histogram |
| Throughput plateaus at exactly N VUs / workers | Generator is the bottleneck (serialized request loop, single-threaded Python GIL, CPU saturated on generator) | Add generator workers; verify generator CPU < 50%; use async HTTP clients |
| p99 is 10× p50 and spiky | Infrequent GC pause or connection pool reuse miss | Profile GC; check connection pool size vs concurrency; look at object allocation rate |
| Load test results vary by 2–3× between runs | Cold start / no warmup; OS page cache cold; JIT not warmed | Add a 1-minute warmup phase before recording metrics |
| Test passes at 50 VU but fails at 100 VU with 502s | Upstream connection pool exhausted; backpressure not implemented | Raise pool size or implement backpressure / circuit breaker |
| Soak test passes at 1h but fails at 4h | Memory leak, connection leak, log disk fill, or token expiry | Instrument RSS over time; add file descriptor monitoring; check log rotation |

### The generator bottleneck — the most common mistake

The load generator becomes the bottleneck more often than people expect. Signs:

- Generator CPU > 70% during the test.
- Request rate plateaus even as you add VUs.
- Removing think time causes *lower* measured throughput (the generator can't schedule fast enough).

Verification: run a trivially fast endpoint (responds with `200 OK` in < 1 ms, no DB) and push load until the generator saturates. Note the max req/s. Every subsequent test must stay well below that ceiling.

```bash
# k6 generator ceiling test — respond with a static 200
k6 run --vus 200 --duration 30s - <<'EOF'
import http from 'k6/http';
export default function () { http.get('http://localhost:8000/_health'); }
EOF
```

### Coordinated omission — war story

> On a Go service I was benchmarking for a past project, Locust reported p99 of 18 ms at 200 concurrent users. The service felt fine in the test. Then we deployed to staging and ran a realistic soak with think time removed (someone's idea of "more aggressive testing"). Users started reporting 1–2 second response times. The difference: in Locust's closed-model default, a slow 800 ms response simply meant that VU's next request was delayed — the generator coordinated its omissions, never actually sending the bursts of requests that a real spike would produce. When we switched to k6 with `ramping-arrival-rate`, the test immediately showed p99 of 780 ms under load — matching what staging users were seeing. The test hadn't been wrong; it had been answering a different question than the one we were asking.

---

## Checkpoint

You're ready for the next module when you can, without looking anything up:

1. Explain the structural difference between open and closed workload models using a diagram or concrete example.
2. State what coordinated omission is and why it causes a load generator to underreport p99 latency.
3. Describe a ramp profile that would catch: (a) throughput saturation, (b) memory leaks.
4. List three signals that indicate the load generator itself — not the server — is the bottleneck.
5. In k6, name the executor that implements an open workload model and sketch its options block.
6. Explain why a zero-think-time load test with 50 VUs is not equivalent to 50 real users.

➡ Next up: **Latency & Percentiles** — why averages lie, tail latency amplification across microservices, and how to read a histogram without being fooled.
