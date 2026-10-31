# Vectorize It

A junior engineer submitted this data-preprocessing function during a code review:

```python
def normalize_and_clip(arr, lo, hi):
    out = []
    for x in arr:
        normed = (x - lo) / (hi - lo)
        out.append(max(0.0, min(1.0, normed)))
    return out
```

On a million-element array it takes several seconds. The reviewer left a comment: *"This is O(n) Python iterations. NumPy can do this in one expression. Please vectorize before merge."*

Your job: reimplement the same computation using NumPy so it passes the hidden pytest harness — which checks both **correctness** (exact same output as the loop) and **speed** (must complete within 1 second on 2 000 000 elements).

## Context

`setup.sh` plants a starter file in your work directory:

```
~/.kube-dojo-work/01-vectorize-it/
├── solution.py          # skeleton with the slow loop reference + your TODO
└── tests/
    └── test_sample.py   # two visible tests: correctness + a tiny perf smoke-check
```

## Prerequisites

```bash
cd ~/.kube-dojo-work/01-vectorize-it
python3 -m venv .venv && . .venv/bin/activate
pip install pytest numpy
```

## Mission

Open `solution.py`. You will find:

1. `_slow_normalize_and_clip(arr, lo, hi)` — the reference Python-loop implementation. Do not modify it.
2. `fast_normalize_and_clip(arr, lo, hi)` — the stub you must fill in.

Rules:
- `fast_normalize_and_clip` must accept the same arguments as the slow version (a plain Python list or a NumPy array, plus `lo` and `hi` floats) and return a **NumPy array**.
- The output values must match the slow version element-by-element within floating-point tolerance (`numpy.allclose`).
- The hidden verifier passes a 2 000 000-element array with a 1-second wall-clock budget. A Python-level `for` loop over that size will time out.

The computation in words: for each element `x`, compute `(x - lo) / (hi - lo)`, then clamp the result to `[0.0, 1.0]`.

## Why vectorization matters

Python executes each loop iteration in the interpreter: type checks, object allocation, reference counting — roughly 50–200 ns per element. NumPy's vectorized operations call into compiled C/Fortran underneath: the entire 2M-element array is processed in a single C loop with SIMD instructions on modern CPUs, taking nanoseconds per element at the C level. The result is a 50–200× speedup for compute-heavy operations — the difference between a preprocessing step that blocks a request and one that's invisible.

The pattern generalizes: any element-wise mathematical transformation (`log`, `sqrt`, `clip`, arithmetic) over a NumPy array should be a single vectorized expression, not a Python loop.

## Verify

```bash
bash courses/course-21-data-science-python/challenges/01-vectorize-it/verify.sh
```

All hidden tests green → flag printed.
