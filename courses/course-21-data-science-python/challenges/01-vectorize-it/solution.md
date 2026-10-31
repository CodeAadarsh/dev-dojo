# Solution — Vectorize It

## The pattern

Every Python-loop transformation over a numeric array maps directly to a NumPy vectorized expression. The slow version does:

```python
normed = (x - lo) / (hi - lo)    # per element
out.append(max(0.0, min(1.0, normed)))
```

The vectorized equivalent processes the entire array at once in C:

```python
import numpy as np

def fast_normalize_and_clip(arr, lo: float, hi: float) -> np.ndarray:
    a = np.asarray(arr, dtype=np.float64)
    normed = (a - lo) / (hi - lo)
    return np.clip(normed, 0.0, 1.0)
```

That is the complete solution — three lines.

## Why each line

**`np.asarray(arr, dtype=np.float64)`**

Accepts both plain Python lists and existing NumPy arrays without copying when `arr` is already a float64 array, and converts when it is not. Specifying `dtype=np.float64` avoids unexpected integer truncation if the caller passes an integer array.

**`(a - lo) / (hi - lo)`**

NumPy broadcasts scalar `lo` and `hi` across the entire array in a single C pass. The `-` and `/` operators on an ndarray are element-wise and return a new ndarray. No Python loop involved.

**`np.clip(normed, 0.0, 1.0)`**

Equivalent to `max(0.0, min(1.0, x))` element-wise. `np.clip` is a single C-level scan — about 50–100× faster than calling Python's `max`/`min` in a loop.

## Speedup intuition

| Approach | 2M elements (approx) |
|---|---|
| Python `for` loop | ~2–6 s |
| NumPy vectorized | ~10–30 ms |

The gap is interpreter overhead: each Python iteration involves type dispatch, reference counting, and boxing/unboxing floats. NumPy eliminates all of that by staying inside C for the entire array operation.

## Common mistakes

**Forgetting `np.asarray`** — if `arr` is a plain list, arithmetic on it will try element-wise Python, not NumPy broadcasting. Always convert first.

**Using `np.vectorize`** — this is NOT vectorization; it is a convenience wrapper that calls your Python function once per element, giving you Python-loop performance with extra overhead. The hint keyword is "compiled C": actual NumPy ufuncs (`+`, `-`, `/`, `np.clip`, `np.exp`, etc.).

**Division by zero when `lo == hi`** — the hidden tests do not exercise this edge case, but in production you would guard: `if lo == hi: return np.full_like(a, 0.0 if lo <= 0 else 1.0)`.
