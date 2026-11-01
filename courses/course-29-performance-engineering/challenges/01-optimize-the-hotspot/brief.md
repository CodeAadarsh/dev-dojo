# Optimize the Hotspot

A nightly batch job in your observability pipeline compares two request logs — a primary capture and a reference snapshot — and reports which API endpoints appear in both. It used to finish in seconds. After a scale-up the logs hit 500 000 entries each, and the job now takes **8 hours**. Your on-call rotation is not happy.

You pull up the profiler flamegraph and the hotspot is obvious: `find_common_endpoints`. It's O(n × m).

## Context

`setup.sh` plants a starter project in your work directory:

```
~/.kube-dojo-work/01-optimize-the-hotspot/
├── hotspot.py           # function under repair — correct but O(n²)
└── tests/
    └── test_hotspot_visible.py   # visible smoke test
```

## Prerequisites

```bash
cd ~/.kube-dojo-work/01-optimize-the-hotspot
python3 -m venv .venv && . .venv/bin/activate
pip install pytest
```

## Mission

Reimplement `find_common_endpoints(log_a, log_b)` in `hotspot.py` so that:

1. **Identical results** — returns the same `set` of endpoint strings as the original for all inputs (empty lists, duplicate entries, no overlap).
2. **O(n + m) complexity** — the verifier uses a _CountedList_ wrapper to count how many times `log_b` is iterated; an O(n²) solution iterates it `n × m` times and will fail.

The function signature and docstring are fixed — only the body changes.

## Why the complexity gap matters

The naive double-loop does 500 000 × 500 000 = 250 billion comparisons. Python's interpreter overhead at ~10–50 M loop iterations/s means 5 000–25 000 seconds — hence the 8-hour job.

Converting each log to a `set` first turns element lookup from O(m) scan to O(1) hash lookup and reduces the job from hours to milliseconds. This is the single most common performance finding in code reviews involving list membership tests.

## Verify

```bash
bash courses/course-29-performance-engineering/challenges/01-optimize-the-hotspot/verify.sh
```

Correct results on all inputs AND complexity proxy passes → flag printed.
