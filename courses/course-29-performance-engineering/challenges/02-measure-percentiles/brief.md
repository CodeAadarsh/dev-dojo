# Measure Percentiles

Your SRE team ships a new dashboard to track API latency. The first alert fires: *"p99 shows 1 ms — that's impossible, our DB alone takes 20 ms."* The bug is in the percentile function. It's using the **nearest-rank** formula, which rounds to the nearest data point instead of interpolating between them. On a small sample it can return values that are off by 20–30%, and it fails completely on single-element lists.

You've been asked to fix the percentile library and add an SLO-breach detector on top of it.

## Context

`setup.sh` plants a starter project in your work directory:

```
~/.kube-dojo-work/02-measure-percentiles/
├── latency_analysis.py   # two stubs: compute_percentile and check_slo
└── tests/
    └── test_latency_visible.py   # visible smoke tests
```

## Prerequisites

```bash
cd ~/.kube-dojo-work/02-measure-percentiles
python3 -m venv .venv && . .venv/bin/activate
pip install pytest
```

## Mission

Implement both functions in `latency_analysis.py`:

### `compute_percentile(data, p) -> float`

Use **linear interpolation** between adjacent sorted values:

```
rank  = p / 100 × (n − 1)
lower = floor(rank)
upper = ceil(rank)          # clamped to n−1
result = data[lower] + (rank − lower) × (data[upper] − data[lower])
```

Requirements:
- Works on unsorted input (sort internally).
- Raises `ValueError` on empty input.
- Returns the single element for a one-element list at any `p`.
- Handles `p = 0` and `p = 100` exactly (first and last elements of the sorted list).

### `check_slo(latencies, p99_threshold_ms) -> bool`

- Returns `True` if the p99 latency **exceeds** `p99_threshold_ms` (SLO breach).
- Returns `False` if p99 is at or below the threshold (SLO met).

## Why linear interpolation

Nearest-rank on 10 samples maps p95 to the 9th or 10th element. Linear interpolation between elements 8 and 9 gives a fractional estimate that converges to the true population quantile as sample size grows. `numpy.percentile` uses the same formula by default — this challenge makes you understand _why_.

## Verify

```bash
bash courses/course-29-performance-engineering/challenges/02-measure-percentiles/verify.sh
```

The verifier asserts exact values (within ±0.01 ms) on known datasets including edge cases.
