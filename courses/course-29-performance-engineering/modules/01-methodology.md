# Performance Methodology

> **Module 01 · Course 29** — Before you write a single benchmark, you need a framework that stops you optimizing the wrong thing. This module is that framework. Speed without measurement is guesswork; measurement without a model is noise.

---

## Measure, Don't Guess

The cardinal rule. Corollary: **the thing you think is slow is rarely the thing that is slow.**

Every production performance incident that involves "we just rewrote the DB query layer" and the p99 didn't move — almost always traces to someone skipping instrumentation and going straight to theory. The fix for a 400 ms endpoint might be a missing index, a serialization hot-loop, a network hop, or a GC pause. You cannot know which until you measure.

What does "measure" actually mean?

- **Instrument before touching code.** Add tracing/metrics to the suspect path *before* changing it. The baseline is everything; without it you can't tell if a change helped.
- **Measure under realistic load.** Microbenchmarks tell you about the microbenchmark, not the system. A `time.time()` wrap around one function call tells you the function; it tells you nothing about contention, caching effects, or JIT warmup.
- **Measure what the user feels.** Latency at the 99th percentile under your actual concurrency profile — not a single synchronous invocation on a warm cache.

---

## USE and RED — Two Models, One Goal

These are the two dominant frameworks for diagnosing where the problem is. Use both; they complement each other.

### USE — for every **resource**

> **U**tilization · **S**aturation · **E**rrors

| Term | What to ask | Example tools |
|------|------------|--------------|
| Utilization | What % of the resource's capacity is in use? | `top`, `mpstat`, `sar`, Prometheus `rate()` |
| Saturation | How much work is *queued/waiting* because it can't be processed? | run-queue depth (`vmstat r`), lock wait time, disk io wait |
| Errors | Is the resource reporting errors? | kernel ring buffer, device error counters, pod OOMKilled events |

Work through your resource list: CPUs, memory, network interfaces, disks, every I/O path. For each one, answer U, S, E. A resource that shows high utilization AND saturation is your bottleneck. A resource with errors is your incident.

Apply USE to Kubernetes: a pod with CPU throttling shows high utilization (near limit) and saturation (throttled cycles). A node with disk pressure shows saturation (io_wait) and possibly errors (ENOSPC events).

### RED — for every **service / request path**

> **R**ate · **E**rrors · **D**uration

| Term | What to ask |
|------|------------|
| Rate | How many requests/s is this service handling? |
| Errors | What fraction are returning errors (4xx, 5xx, exceptions)? |
| Duration | What is the distribution of request latency? (not just the mean) |

RED is the *external* view — what the consumer experiences. USE is the *internal* view — what the infrastructure is doing. In a Grafana dashboard you typically have RED panels at the top (service health at a glance) and USE panels below (why).

At SAP on an LGTM ingest pipeline: RED caught that error rate spiked during batch windows. USE then found the culprit — disk write saturation on the Mimir chunk store, because the I/O was queued behind a GC-induced write stall. Neither framework alone would have been enough.

---

## Workload Characterization

Before you benchmark, understand your workload. A load profile that doesn't resemble production is a benchmark that proves nothing.

**Characterize along these axes:**

1. **Request rate** — requests/second, and how it varies (steady, bursty, diurnal).
2. **Concurrency** — how many concurrent users/connections? (relates to Little's Law, covered in Module 05.)
3. **Request mix** — what fraction reads vs writes? Simple lookups vs expensive aggregations?
4. **Data size** — payload sizes, result set sizes. A 10-byte response and a 10-MB response behave entirely differently under the same request rate.
5. **Think time** — how long does a real user wait between requests? Zero think time (scripted hammering) produces a closed workload that may not reflect reality.

**Practical approach for a new service:**

```
1. Tail production logs for 15 minutes.
2. Extract: request paths, methods, response sizes, response times.
3. Compute percentile distributions — not averages.
4. Use that distribution as your load model.
```

If you don't have production logs yet: use domain knowledge (read-heavy? write-heavy?) and err toward a workload that stresses the path you least want to fail.

---

## Micro vs Macro Benchmarks

| Type | What it measures | When to use it | What it misses |
|------|-----------------|----------------|----------------|
| Microbenchmark | One function / operation in isolation | Confirming a hot function is actually faster after a change | System effects: cache eviction, GC, contention, network |
| Macro / integration benchmark | The full request path end-to-end | Checking that a change moves user-observable latency | Root cause — you know it changed but not why |

The workflow is: **macro to detect**, **micro to explain**, **macro to confirm**.

Never use a microbenchmark as the sole evidence that a change is an improvement. It is evidence that *the function* is faster. Whether users notice is a different question.

**Python note.** `timeit` and `pytest-benchmark` work well for micros. Use them when you need to compare two implementations of the same function. But run with `--warmup` iterations so the JIT/interpreter's bytecode compilation effects don't contaminate your first measurement.

---

## Establishing a Baseline

A baseline is a set of metrics collected under a known, controlled, repeatable workload. Without it, "is this change better?" has no answer.

**What a good baseline includes:**

- Commit SHA of the code under test.
- Python version, OS, hardware class (or cloud instance type).
- Load profile: concurrency, duration, request rate.
- Key metrics: p50/p95/p99 latency, throughput (requests/s), error rate, CPU%, memory RSS.
- Environment state: warm cache or cold? JVM / interpreter already warmed up?

**Repeatability matters more than absolute numbers.** A p99 of 34 ms on your Mac Mini means nothing to your colleague on a different machine. What matters is that *your* p99 before the change was 34 ms and *after* it's 21 ms under the same conditions — that's a 38% improvement, and that number travels.

```bash
# Minimal baseline capture for a Python service
hyperfine \
  --warmup 5 \
  --runs 50 \
  --export-json baseline.json \
  'python3 -I service_bench.py'
```

Store `baseline.json` in git alongside the code change. If you can't reproduce the baseline, you can't claim improvement.

---

## The Benchmarking Fallacies

These are the ways otherwise careful engineers produce meaningless benchmark results.

| Fallacy | Mechanism | Antidote |
|---------|-----------|----------|
| **Cold vs warm measurement** | First N iterations prime CPU instruction cache, interpreter bytecode cache, disk page cache, and connection pools. Measurements before warmup are measuring startup, not steady-state. | Always include a warmup phase. Discard first-N results. |
| **Coordinated omission** | When the load generator *waits* for a response before sending the next request, a slow response reduces the request rate. A 500 ms response at 10 rps "hides" the 40 pending requests that would have arrived. Reported p99 is optimistic. | Use open workload models; compensate for start time; see Module 02. |
| **Benchmark amplification** | The benchmark itself becomes the bottleneck (serialized request loop, logging overhead, single-threaded result collection). | Verify that the generator CPU is not saturated; validate with a trivial no-op endpoint first. |
| **Single-run variance** | One run of a benchmark is a single sample. GC pauses, OS scheduling noise, thermal throttling, and network jitter add variance. | Run ≥ 20 iterations and report the distribution, not the single run. |
| **Wrong metric** | Measuring throughput when users feel latency. Measuring mean latency when SLA is at p99. Measuring RPS under zero-think-time when production users have think time. | Define the user-facing SLO first; derive the metric from that. |
| **Artificial workload** | Test data that fits in L3 cache when production data does not. | Benchmark with data at realistic scale: if your production table has 50M rows, your benchmark should too. |

---

## Debugging Performance Methodology

### Symptom → Cause → Fix

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| "I optimized function X but latency didn't change" | X is not on the hot path; the actual hotspot is elsewhere | Profile first: confirm X is in the top N% CPU time before touching it |
| "My benchmark shows 2× speedup but production is unchanged" | Microbenchmark does not represent the real workload; cache effects, I/O, or GC dominate at scale | Switch to a macro benchmark; instrument the real path in production |
| "Benchmark results vary ± 30% between runs" | Insufficient warmup, GC pauses, OS jitter, thermal throttling | Increase warmup iterations; pin CPU frequency; run more iterations and report stddev |
| "Benchmark shows improvement but error rate went up" | Optimization broke a correctness invariant (e.g., dropped a lock, skipped validation) | Correctness tests must pass before performance claims are valid |
| "Can't reproduce colleague's benchmark result" | Different hardware, OS scheduler, Python version, or cache state | Capture environment metadata; containerize the benchmark |

### JIT Warmup and Caching — the two most common benchmark lies

**JIT warmup (Python / JVM):** CPython compiles source to bytecode on first import, and many C extensions initialize data structures on first call. If your benchmark times the *first* call, you are measuring initialization, not steady-state. Always measure after a warmup phase where the code path has been exercised at least once. With `pytest-benchmark`, use `--benchmark-warmup=on`.

**Cache inflation:** In-memory data structures, OS page cache, and CPU caches all warm up during the first few iterations. A benchmark that sees 10 µs on iteration 1 and 0.3 µs on iteration 100 is showing cache fill, not a hot-loop optimization. Report per-iteration time *after* the cache is hot, and always note whether the measurement is cold-cache or warm-cache, because your production system is almost always warm.

> **War story.** During an LGTM pipeline load test at SAP, our initial benchmark showed a 3× throughput improvement from switching to a batch write path. Looked great on the dashboard — until we noticed the benchmark was running against an in-memory mock with a 100-row dataset. In production, the object store had millions of rows and the batch path triggered full-table scans on index builds. The "optimization" was 40% *slower* in production. The fix: benchmark with a representative data volume (≥ 1M rows) and measure against the real store, even in staging. A benchmark that doesn't exercise your bottleneck is a liability, not an asset.

---

## Checkpoint

You're ready for the next module when you can, without looking anything up:

1. State the USE acronym and apply it to a CPU-bound Kubernetes pod (what are utilization, saturation, and errors for that pod?).
2. State the RED acronym and describe how it complements USE rather than replacing it.
3. Explain the difference between a micro and a macro benchmark, and give the correct order of operations for using both.
4. Name three of the six benchmarking fallacies and explain the mechanism for each.
5. Describe what a baseline must contain to be reproducible by someone else on different hardware.
6. Explain why a benchmark showing 2× speedup in a microbenchmark is not sufficient evidence to ship a performance change.

➡ Next up: **Load Testing** — open vs closed workload models, think time, ramp profiles, and how coordinated omission makes your load generator a liar.
