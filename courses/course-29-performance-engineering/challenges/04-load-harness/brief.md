# Build a Load Harness

A ticket lands in your queue: *"The checkout service SLO says p95 < 120 ms. We have a benchmark from six months ago. Nobody knows if it still holds. Write a harness that can tell us."*

You reach for k6 or Locust, but the infra team has locked down external tool installs on the benchmark host. You have Python, `threading`, and the stdlib. That is enough — knowing how to build the thing teaches you what every load tool does under the hood.

## Context

`setup.sh` plants a starter project in your work directory:

```
~/.kube-dojo-work/04-load-harness/
├── harness.py          # skeleton — implement run_load()
├── stub_server.py      # deterministic target stub — do NOT modify
└── tests/
    └── test_visible.py # two smoke tests; run these first
```

The stub simulates a backend with configurable latency: it sleeps `latency_ms` milliseconds per call and records the peak number of concurrent callers. `verify.sh` uses its own inline copy of the stub so it is tamper-resistant — touching `stub_server.py` does not help.

## Prerequisites

```bash
cd ~/.kube-dojo-work/04-load-harness
python3 -m venv .venv && . .venv/bin/activate
pip install pytest
```

## Mission

Implement `run_load(target_fn, n_requests, concurrency)` in `harness.py`.

`verify.sh` checks **all five** of these properties:

| Check | What the verifier asserts |
|-------|--------------------------|
| Total requests | `result.total_requests == n_requests` |
| Concurrency cap | `stub.max_observed_concurrent <= concurrency` |
| Actually concurrent | `stub.max_observed_concurrent >= 3` when `concurrency=10` |
| Latencies measured | `len(result.latencies_ms) == n_requests` and `p95_ms >= 1.0 ms` |
| Throughput reported | `result.throughput_rps > 0` |

The concurrency cap is enforced by the *number of in-flight calls*, not the number of spawned threads. A Semaphore or `ThreadPoolExecutor(max_workers=concurrency)` both work.

## Why this matters

Every load tool — k6, Locust, wrk, JMeter — is, at its core, this loop:

1. Maintain a pool of concurrent workers (closed model) or a target arrival rate (open model).
2. Record per-request latency.
3. Aggregate latencies into percentiles at the end.

Once you have built it yourself you will know exactly what "concurrency" means in each tool, why the open model produces coordinated omission if you are not careful, and why p95 is the right SLO anchor (the mean hides the tail that your slowest users feel).

## Verify

```bash
bash courses/course-29-performance-engineering/challenges/04-load-harness/verify.sh
```

All five checks green → flag printed.
