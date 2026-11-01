# Profiling

> **Module 04 · Course 29** — A profile is a map. Before you change a line of performance-critical code, you need a map that tells you where the time is actually spent. Without one, you're navigating by feel — and the first thing every experienced engineer will ask when you claim a speedup is "did you profile first?"

---

## CPU vs Wall-Clock vs Memory Profiling

These are three different questions. Conflating them is one of the most common profiling mistakes.

### CPU profiling

Measures time the process spends **executing on a CPU core** — instructions running, not waiting. Excludes I/O wait, lock wait, sleep, and any time the OS preempted the process.

**Use it for:** compute-bound workloads. Tight loops, heavy parsing, compression, serialization, cryptography, mathematical operations.

**Doesn't show:** I/O latency, lock contention, time waiting on a database or network call.

### Wall-clock profiling

Measures **elapsed real time**, including I/O wait, sleep, lock wait, and preemption. A function that calls `time.sleep(1)` uses 0 CPU time but 1 second of wall time.

**Use it for:** I/O-bound workloads, anything involving network calls, database queries, or inter-process communication. If your service is slow and the CPU profiler shows nothing hot, the bottleneck is I/O — switch to wall-clock.

**Doesn't show:** precisely where CPU cycles go (high wall time on a pure-CPU function = both are the same, but a function calling `sleep` looks expensive on wall, not on CPU).

### Memory profiling

Measures **heap allocations** — how much memory each code path allocates, how many objects are alive at a given time, and where unreleased references accumulate (leaks).

**Use it for:** investigating high memory usage, GC pressure (excessive short-lived allocations), or memory growth over time (leaks).

**Doesn't show:** CPU or I/O time.

**Rule:** run a CPU profile first. If CPU time is low but the system is slow, run wall-clock. If memory usage is high or growing, run memory profiling.

---

## Sampling vs Instrumentation

Profilers fall into two camps. The right choice depends on production safety and overhead tolerance.

### Sampling profiler

Periodically interrupts the program (e.g., every 10 ms) and records the current call stack. After N samples, you have a statistical picture of where time is spent.

**Pros:**
- Low overhead (1–5% CPU typically). Safe to run in production.
- No code changes required.
- Works on already-running processes (`py-spy attach --pid <PID>`).

**Cons:**
- Statistical — rare but expensive functions may be missed if sampling rate is too low.
- Doesn't capture every call, only samples.

**Python tool:** `py-spy` — attaches to a running process without restarting it.

### Instrumentation profiler

Wraps every function call with timing code. Records entry time, exit time, and call count for every function.

**Pros:**
- Complete — every call is recorded.
- Exact call counts and per-call timing.

**Cons:**
- High overhead (often 2–10× slowdown). Not safe for production workloads.
- Can change program behavior (Heisenberg effect — profiling overhead alters timing of locks, GC, I/O).

**Python tool:** `cProfile` (stdlib) — instrumentation profiler.

```python
import cProfile
import pstats
from io import StringIO

pr = cProfile.Profile()
pr.enable()

# code under test
do_expensive_thing()

pr.disable()
s = StringIO()
ps = pstats.Stats(pr, stream=s).sort_stats('cumulative')
ps.print_stats(20)   # top 20 functions by cumulative time
print(s.getvalue())
```

**Rule:** use sampling in production (or on a live-traffic staging copy). Use instrumentation in development when you need exact call counts.

---

## Flamegraphs

A flamegraph is a visualization of a sampling profile that makes the call stack hierarchy and time distribution immediately readable.

```
│                                                              │
│          handle_request (12%)                                │
│  ┌─────────────────────────────────────────────────────┐    │
│  │   parse_body (3%)  │  validate (1%)  │  db_query (8%)│   │
│  └─────────────────────────────────────────────────────┘    │
│                            │             │                   │
│                        validate_schema  │  execute_sql (7%) │
│                                         │                   │
│                                      connection_acquire (6%)│
```

**How to read a flamegraph:**
- **X-axis:** sorted alphabetically by function name (not time order). Width = % of samples where this function appears in the stack.
- **Y-axis:** call depth. Bottom = entry point; top = leaf functions.
- **Wide boxes at the top:** hot leaf functions — where time is actually spent.
- **Wide boxes in the middle:** functions that transitively account for many samples — possibly the entry point to a hot subtree.

**What to look for:**
- A wide plateau at the top (leaf level) = CPU hotspot.
- A wide tower with a single path = a chain of wrappers over a hot function.
- Most of the width consumed by I/O primitives (socket read, file write) = I/O bound; CPU profiling won't help.

### Generating flamegraphs with py-spy

```bash
# Install
pip install py-spy

# Sample a running process and generate an SVG flamegraph
py-spy record -o profile.svg --pid <PID> --duration 30

# Or run a script under py-spy
py-spy record -o profile.svg -- python3 -I my_service.py

# Top-mode (live terminal view, like top for stack traces)
py-spy top --pid <PID>
```

Open `profile.svg` in a browser — it's interactive; click a frame to zoom in.

### Generating flamegraphs with pprof (Go / generic)

```bash
# Go: profile built in
go tool pprof -http=:8080 http://localhost:6060/debug/pprof/profile?seconds=30

# Generates a flamegraph viewable in browser
```

### Linux perf (production node)

```bash
# Record 30 seconds of CPU samples for PID
perf record -F 99 -p <PID> -g -- sleep 30

# Generate flamegraph (needs Brendan Gregg's scripts)
perf script | stackcollapse-perf.pl | flamegraph.pl > profile.svg
```

`perf` works for any language but requires kernel symbols and debug info. In a Kubernetes pod, you may need a privileged debug container or a DaemonSet with `SYS_PERF_EVENT` capability.

---

## Allocation Profiling and GC Pressure

In garbage-collected languages (Python, Java, Go), excessive allocation causes GC pressure — frequent GC runs that pause the application or consume a large fraction of CPU.

**Signs of GC pressure:**
- Memory profiler shows many small, short-lived objects.
- GC pauses visible in latency histograms (periodic p99 spikes at GC interval).
- Prometheus `go_gc_duration_seconds` or Python `gc.get_count()` showing high frequency.
- CPU profiler shows significant time in `gc:collect`, `PyObject_GC_Del`, or equivalent.

**Python-specific allocation profiling:**

```python
import tracemalloc

tracemalloc.start()
# code under test
snapshot = tracemalloc.take_snapshot()
top_stats = snapshot.statistics('lineno')
for stat in top_stats[:10]:
    print(stat)
```

`tracemalloc` shows which lines allocated the most memory, which is distinct from where time is spent.

**Common GC pressure patterns:**

| Pattern | Mechanism | Fix |
|---------|-----------|-----|
| Lots of small string concatenations | Each `+` creates a new string object | Use `str.join()` or `io.StringIO` |
| Building large lists item by item in a tight loop | Many intermediate lists | Pre-allocate or use generators |
| Deserialization creating millions of small dicts | JSON/msgpack creates a new dict per object | Use a dataclass or attrs; reuse buffers |
| Creating objects in a hot loop instead of a pool | GC runs proportional to allocation rate | Object pool pattern; reuse instances |

**Memory leak vs memory bloat:**
- **Leak:** memory that grows indefinitely. Objects that should be freed are being retained (e.g., a growing cache with no eviction, a list that appends but never pops).
- **Bloat:** memory is high but stable. The program legitimately needs it (a large cache that's working as intended, a large data structure in memory).

Distinguish them by plotting RSS over time. A leak grows continuously. Bloat plateaus.

---

## Finding the Hotspot Before Optimizing

The sequence matters:

```
1. Profile under realistic load (not idle)
2. Identify the top-N functions by cumulative time (CPU) or allocation size (memory)
3. Verify these are on the actual hot path (not test scaffolding, not logging)
4. Optimize the top function
5. Re-profile to confirm the hotspot moved
6. Repeat until the system meets the SLO
```

**Do not skip step 5.** After an optimization, the profile changes. What was the second-biggest hotspot may now be the first. Or the function you optimized was a wrapper and the real hotspot is still below it.

**The 80/20 rule of hotspots:** typically, fixing the top 1–2 hotspots accounts for 80%+ of the improvement. If you've fixed the top 10 things and p99 hasn't moved, you're either not measuring correctly or the bottleneck is external (network, database, downstream service).

---

## Debugging Profiling

### Symptom → Cause → Fix

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| CPU profiler shows nothing hot but service is slow | I/O bound — CPU profiling won't show I/O wait | Switch to wall-clock profiler; add tracing to DB/network calls |
| Flamegraph shows all time in non-application frames (epoll, socket_read) | Network or disk I/O dominates; bottleneck is external | Measure I/O latency directly; check downstream service p99 |
| Optimization of function X had no effect on end-to-end latency | X was not the bottleneck; another function dominates | Re-profile; use cumulative time sort to find the actual top function |
| Memory grows indefinitely in production but not in tests | Memory leak: a cache, list, or registry grows unboundedly | Use `tracemalloc` snapshots over time; look for objects that grow; add eviction |
| p99 spikes every ~30 seconds | GC pause at GC trigger interval | Profile GC frequency and duration; reduce allocation rate; tune GC thresholds |
| Profiler output shows function names but no line numbers | Debug symbols stripped or pycache stale | Run with `py-spy` in source mode; ensure `--no-optimize` / `-B` flag for CPython |
| Optimization 2× faster in microbenchmark, no change in production | Real workload has I/O, lock contention, or different data shape | Benchmark with realistic data and concurrency; profile under concurrent load |

### Optimizing a non-hotspot — the most expensive mistake

You can spend a week making a function 10× faster and see zero improvement in production if that function contributes 0.1% of the total time. This is why profiling before optimizing is not optional.

> **War story.** A colleague inherited a Python data pipeline at SAP that was taking 45 minutes to run. The code had clearly expensive-looking regex matching on every row, so they spent three days rewriting it with a compiled automaton library — 8× faster in a microbenchmark. The pipeline still took 44.5 minutes. Profiling it afterward (not before — that was the mistake) showed the regex was 1.2% of total runtime. The actual hotspot was a nested loop building a lookup dict on every row — quadratic in the input size. Fixing the O(n²) loop took 2 hours and brought the runtime to 3 minutes. Profile first. The most obviously "slow-looking" code is often not the bottleneck.

### GC thrash — how to find it

> At a previous project, a Python ingestion service showed periodic latency spikes every 15–20 seconds. The CPU profile during normal operation looked clean. Adding `gc.set_debug(gc.DEBUG_STATS)` to a staging copy revealed the GC was running a full collection every ~18 seconds, taking 180 ms — exactly matching the latency spikes. Root cause: a deserialization loop was creating 50,000 small dicts per batch that all survived into gen-2 GC. Fix: replaced the dict-heavy deserialization with `__slots__`-based dataclasses, cutting allocation by 60%. Gen-2 GC frequency dropped 5× and the latency spikes disappeared. The lesson: GC pauses are invisible to CPU profilers. Track GC metrics separately.

---

## Checkpoint

You're ready for the next module when you can, without looking anything up:

1. State the difference between CPU profiling and wall-clock profiling. Give an example of a workload where each one is the correct choice.
2. State the difference between a sampling profiler and an instrumentation profiler. Explain why you would use `py-spy` in production instead of `cProfile`.
3. Read a flamegraph: given a wide box at leaf level consuming 60% of width, what does that tell you, and what is your next step?
4. Explain GC pressure: how does allocation rate cause latency spikes, and how would you detect it?
5. Explain the difference between a memory leak and memory bloat. How do you distinguish them from a time-series graph of RSS?
6. Describe the correct sequence of steps between "the service is slow" and "I am confident the optimization helped."

➡ Next up: challenges — you'll apply profiling, load testing, and latency analysis in a series of pytest-judged exercises on local Python workloads.
