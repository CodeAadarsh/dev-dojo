# Concurrency & Throughput

> **Module 05 · Course 29** — Most services fall over not because a single request is slow, but because too many hit at once and the system backs up. This module gives you the physics of that backup: Little's Law, queueing theory, and the Universal Scalability Law. Once you can see saturation coming in the math, you can size worker pools correctly and design backpressure instead of discovering it during an incident.

You already know threads and async exist. This module is about *why* the numbers you reach for when sizing them are usually wrong, and what to use instead.

---

## Little's Law — the throughput triangle

Little's Law is a queueing identity, not an approximation:

```
L = λ × W
```

| Symbol | Meaning | Concrete unit |
|--------|---------|---------------|
| `L` | Mean number of requests in the system (queue + service) | requests |
| `λ` (lambda) | Arrival rate (throughput) | requests / second |
| `W` | Mean time a request spends in the system (latency) | seconds |

It's **exact** for any stable, ergodic system regardless of arrival distribution. Rearranging gives you the two decisions you care about:

```
λ = L / W          # max throughput for a given concurrency cap and target latency
L = λ × W          # how many in-flight at steady state
W = L / λ          # what latency to expect at a given concurrency and rate
```

### Working example

Your FastAPI service processes 200 req/s. Each request takes 50 ms end-to-end.

```
L = 200 req/s × 0.05 s = 10 requests in-flight at any instant
```

So you need **at least 10 workers** to not immediately queue. If you set your thread pool to 5, you'll be at 100% utilization from the first second of load and latency will climb unboundedly.

> Rule of thumb: set `pool_size ≥ ceil(λ_peak × W_p99)`. Use the p99 latency, not the mean — otherwise you'll be perpetually undersized because the mean hides the tail.

### Little's Law does not tell you what W is

The biggest trap: W depends on utilization, and utilization depends on λ. At low load, W is your service time. As you approach capacity, W explodes because requests queue. That interaction is queueing theory's job.

---

## Queueing theory: the utilization vs latency knee

For a single-server queue (M/M/1), mean wait time in queue is:

```
W_q = (ρ / (1 - ρ)) × (1 / μ)
```

where `ρ = λ / μ` is **utilization** (arrival rate ÷ service rate) and `μ` is the service rate (requests per second the server can handle).

```
   latency
     │
     │                          ╭──
     │                        ╭─╯
     │                      ╭─╯
     │                  ╭──╯
     │             ╭───╯
     │────────────╯
     └─────────────────────────────── utilization ρ
     0%    50%   70%   80%  90% 100%
```

The curve is nonlinear and has a **knee around 70–80% utilization** for typical M/M/1 queues. At 90% utilization, mean wait time is 9× the service time. At 95% it's 19×. At 99% it's 99×.

**Practical consequence:** never target more than 70% CPU/worker utilization in a latency-sensitive service. The last 30% of headroom buys you nonlinear safety margin. "We're only at 80% — we're fine" is how you end up on-call at 3 AM.

### M/D/1 and real services

Real services are closer to M/D/1 (deterministic service time, like a tight compute loop) where the knee is less steep. But they also have multi-stage pipelines, shared resources (DB connections), GC pauses, and coordinated request arrivals — all of which push behavior toward or past M/M/1. Assume M/M/1 as your conservative model.

---

## Worker and connection pool sizing

### Thread pools (CPU-bound work)

```python
# rule: workers ~ CPU cores × (1 + wait_fraction)
# wait_fraction = fraction of time spent blocking (IO, sleep, network)
# pure compute: workers = cpu_count
# IO-heavy: workers = cpu_count * (1 + blocking_ratio)  e.g. 4 * (1 + 4) = 20
import os
WORKERS = int(os.cpu_count() * (1 + BLOCKING_RATIO))
```

For an async framework (asyncio, Vert.x, Netty), the event loop thread count should equal the number of physical cores for CPU-heavy handlers. All blocking calls must be offloaded to a thread pool executor — one blocking call on the event loop blocks *every* coroutine sharing that loop.

### Connection pools (DB/cache)

The classic mistake: pool_size = thread_count. Wrong. The DB has its own concurrency limit (max_connections, pgbouncer pool, etc.). A 200-thread app pointing at a Postgres with `max_connections=100` and `pool_size=200` will queue 100 connections, adding latency and risking timeout cascades.

```
pool_size = min(thread_count, db_max_connections / service_replica_count)
# leave 10–20% of db_max_connections for admin/maintenance sessions
```

For read replicas add a separate pool. For a microservice pointing at Redis: typical max is 10k connections, so pool_size of 10–50 per instance is fine — but watch `WAIT` latency in `redis-cli info stats` if you ever see timeouts.

### The idle pool cost

Connections are not free. Each Postgres connection holds backend memory (~5–10 MB). A pool of 100 connections per service × 20 replicas = 2000 connections = 10–20 GB just in backend state. Size pools to your *p95 concurrency*, not your *max* concurrency. Use HikariCP-style connection acquisition metrics (`pool.Wait`, `pool.Usage`) to find the real steady-state number.

---

## Backpressure

Backpressure is **telling producers to slow down when consumers are falling behind**. Without it, queues grow until memory exhausts or latency climbs to the point of timeout cascades.

```
              no backpressure                     backpressure
  ┌──────────┐                     ┌──────────┐
  │ producer │──────────→ buffer ──→│ consumer │
  │  10k/s   │   [grows forever]   │  8k/s    │
  └──────────┘                     └──────────┘

  vs.

  ┌──────────┐   "slow down" signal  ┌──────────┐
  │ producer │←──────────────────────│ consumer │
  │  10k/s   │──→ bounded queue ────→│  8k/s    │
  └──────────┘   [shed or throttle]  └──────────┘
```

Implementations by layer:

| Layer | Backpressure mechanism |
|-------|----------------------|
| HTTP/2 | flow control windows (WINDOW_UPDATE frames) |
| gRPC streaming | same HTTP/2 flow control |
| Kafka consumer | consumer lag — but the app must check lag and rate-limit upstream |
| Go channels | `ch <- item` blocks when channel is full — free backpressure if buffer is bounded |
| Asyncio | bounded `asyncio.Queue(maxsize=N)` — `await queue.put()` blocks the producer |
| Thread pool | `ThreadPoolExecutor` with bounded queue — `submit()` raises `Full` |

The **shed vs queue vs propagate** decision:
- **Shed (drop)**: best for stateless, idempotent requests where retry is cheap. Return 429.
- **Queue**: only if latency budget allows. A queue with no drain rate limit is just delayed shedding.
- **Propagate upstream**: ideal for streaming pipelines. Requires the upstream to respect it.

---

## Universal Scalability Law

The USL is a model of how throughput scales with parallelism N:

```
X(N) = λN / (1 + σ(N − 1) + κN(N − 1))
```

| Term | Parameter | Cause |
|------|-----------|-------|
| `σ` (sigma) | **Contention** | Serialization — a shared lock, a single DB write path, anything that only one thread can do at a time |
| `κ` (kappa) | **Coherence** | Consistency overhead — cache invalidation, distributed coordination, replicated state that every node must sync |

Three regimes:

```
throughput
     │
     │     linear scaling (σ=0, κ=0 — ideal)
     │   ╱─────────────────────────────────────
     │  ╱  Amdahl plateau (σ>0, κ=0)
     │ ╱───────────────────────
     │╱  USL retrograde (σ>0, κ>0)
     │╱─────────────────────────────── and back down
     └────────────────────────────────────── N (workers)
```

**Retrograde scaling** — adding more threads *reduces* throughput — happens when `κ` dominates. You see this with: global interpreter lock (Python threads on CPU-bound work), excessive cache invalidation traffic in multi-core systems, or a distributed lock that every node must acquire.

To measure your system's σ and κ: run load tests at N = 1, 2, 4, 8, 16, 32 workers and fit the USL curve. Tools like `pyperf`, `wrk`, or `locust` with stepped concurrency can collect the data. A σ above 0.1 is a red flag — you have a serialized bottleneck eating 10%+ of your scaling budget.

---

## Debugging Concurrency & Throughput

### Symptom → Cause → Fix

| Symptom | Likely cause | Diagnosis | Fix |
|---------|-------------|-----------|-----|
| Latency climbs steadily under constant load | Pool undersized; utilization past the knee | `pool.activeCount / pool.size` > 80%; `pool.awaitingConnection` > 0 | Increase pool size to `ceil(λ_p99 × W_p99)`; verify with Little's Law |
| Throughput plateaus and drops as concurrency increases | Contention (lock, GIL, single-writer bottleneck) | Profile with `py-spy`, `async-profiler`; look for a single function dominating wall time | Shard the lock; use lock-free structures; switch to process-level parallelism for CPU-bound Python |
| Queue depth grows unboundedly; OOM after ~15 min | No backpressure; producer outpaces consumer | `queue.qsize()` trend monotonically up; memory grows linearly | Cap queue at a bounded size; shed or propagate upstream when full |
| p99 latency spikes every ~2 minutes on a consistent schedule | GC pause (Java: G1 stop-the-world; Python: cyclic GC) | Correlate GC logs with latency spikes; `gc.callbacks` in Python; GC log in JVM `-Xlog:gc*` | Tune GC (G1 region size, survivor ratio); reduce allocation rate; use `gc.disable()` for latency-critical hot paths (with explicit `gc.collect()` at idle) |
| Adding replicas makes p99 *worse* | Coherence cost: shared state (distributed cache invalidation, leader election ping) | USL κ term — benchmark at 1, 2, 4, 8 replicas; throughput per replica should not drop | Partition state; make replicas independent (shard by key); use eventual consistency where possible |
| Worker pool is large but CPU is idle; p50 latency is high | Blocked threads — IO without async, lock contention, or sleep in hot path | `jstack`/`pstack` all threads; most show `WAITING` or `BLOCKED` on a monitor | Move blocking IO to async or a dedicated IO thread pool; never sleep in the event loop |

> **War story.** A recommendation service at a previous SDE role had a thread pool of 200 and a Postgres pool of 200. Under load testing, throughput plateaued at ~400 req/s and p99 was 800ms. Postgres `max_connections` was 100. The connection pool was throwing 100 threads into a wait state half the time. Little's Law said we needed ~20 connections at steady state (400 req/s × 50ms service time = 20). We dropped the pool to 30, reserved 10 for admin, and throughput jumped to 1200 req/s — 3× — without touching a line of application code. The bottleneck was not slow code; it was misapplied math.

---

## Checkpoint

You're ready for the challenges when you can, without looking anything up:

1. State Little's Law and rearrange it to answer: "at 300 req/s with 80 ms p99, how many workers do I need minimum?"
2. Explain the utilization–latency knee: why does 80% CPU feel fine until it doesn't?
3. Give the rule for sizing a DB connection pool for a service running 10 replicas against a Postgres with `max_connections=200`.
4. Name three places in a system where backpressure is built-in versus three where you must implement it explicitly.
5. Explain, in two sentences, what `σ` (contention) and `κ` (coherence) mean in the USL and give one code-level example of each.
6. Describe a production symptom that is definitively "retrograde scaling" and how to measure σ and κ from load test data.
7. Name two tools you'd use to find a serialized bottleneck consuming > 10% of wall time in Python and in Java.

➡ Next up: **Caching & Data-Path Tuning** — keeping hot data close and eliminating work you never needed to do.
