# NumPy & Vectorization

> **Module 01 · Course 21** — NumPy is not a library you sprinkle on top of Python; it is a different execution model. The gap between a Python loop and a NumPy ufunc is not a constant factor — on production-scale arrays it is 50–200x. This module explains *why*, then gives you the mental model to write vectorized code from scratch instead of just copying patterns you've seen.

You already write Python fluently and probably use NumPy already, so this skips the "here is an array" basics and goes straight for the internals. Once you understand what NumPy actually does in memory you stop needing to Google "how to vectorize X" — the answer follows from the model.

---

## The ndarray is not a Python list

A Python list is an array of **pointers to heap objects**. Each element — even a small integer — is a separately allocated Python object with a type tag, a reference count, a hash, and the value. A small int is about 28 bytes before you count the pointer in the list.

```
Python list [1, 2, 3, 4]

  list object
  ┌──────────────┐
  │  ob_size = 4 │
  │  items ──────┼──► [ ptr0 | ptr1 | ptr2 | ptr3 ]
  └──────────────┘       │       │       │       │
                      int(1)  int(2)  int(3)  int(4)
                      (28B)   (28B)   (28B)   (28B)
                      scattered across the heap
```

A NumPy ndarray is one **contiguous block of raw bytes** with a dtype header that tells the library how to interpret those bytes.

```
numpy array [1, 2, 3, 4]  dtype=int64

  ndarray object
  ┌────────────────────────────────────┐
  │  data   ──► ┌──────────────────┐  │
  │  dtype=int64│  0x01 00 00 00   │  │
  │  shape=(4,) │  00 00 00 00     │  │  ← element 0, little-endian int64
  │  strides=(8)│  0x02 00 00 00   │  │
  │  ...        │  00 00 00 00     │  │  ← element 1
  └────────────────────────────────────  ...32 bytes total, contiguous
```

Two direct consequences:

**Cache locality.** Modern CPUs have L1/L2 caches of 32–256 KB. When you stream through a flat buffer, the hardware prefetcher loads ahead — effectively free reads. A Python loop chasing scattered heap pointers thrashes the cache because every element lives at a random address.

**SIMD.** Your M2's NEON/AMX unit operates on 128–256 bits at once. On `float32`, that's 4–8 additions per instruction. NumPy's C extensions issue these instructions; the Python interpreter never can because the interpreter dispatch overhead is *per-element* — it dominates all computation.

The speedup is therefore not linear in loop size — it *grows* with array size because interpreter overhead is constant per element while SIMD throughput is constant per *batch*.

---

## dtypes — the NumPy type system

```python
import numpy as np

a = np.array([1, 2, 3])            # inferred: int64 on 64-bit systems
b = np.array([1.0, 2.0, 3.0])      # float64
c = np.array([True, False, True])   # bool_
d = np.zeros(4, dtype=np.float32)   # explicit — 4 bytes per element, not 8
e = np.empty((3, 3), dtype=np.int32)

a.dtype    # dtype('int64')
a.itemsize # 8   bytes per element
a.nbytes   # 24  total bytes in the data buffer
```

Common dtypes:

| dtype | bytes | use |
|-------|-------|-----|
| `bool` | 1 | boolean masks |
| `int32` | 4 | IDs, small counts |
| `int64` | 8 | default int |
| `float32` | 4 | ML weights, feature matrices |
| `float64` | 8 | default float, precision-sensitive math |
| `object` | 8 (ptr) | mixed types, strings — kills vectorization |

`dtype=object` is NumPy's escape hatch: it stores Python pointers, so you get the memory overhead of NumPy on top of the cache-thrashing of pointer chasing. Whenever you see `a.dtype == object`, treat it as a bug.

**Explicit dtype saves memory and improves throughput.** A float32 array of 10M elements is 40 MB vs 80 MB for float64. On your M2 with 8 GB shared between CPU and GPU, this matters.

```python
X = np.random.randn(1_000_000).astype(np.float32)
X.nbytes  # 4_000_000 — half the memory of float64
```

**Integer overflow is silent.** NumPy does not raise on overflow — it wraps around.

```python
np.array([127], dtype=np.int8) + np.array([1], dtype=np.int8)
# array([-128], dtype=int8)  — no warning
```

Check your dtype before accumulating large sums.

---

## Shapes and axes

An array's `shape` is a tuple; each element is the size of one **axis** (dimension). Axes are indexed from 0 starting at the outermost (leftmost) dimension.

```python
a = np.arange(24).reshape(2, 3, 4)

#  axis 0 — size 2 (two "slabs")
#  axis 1 — size 3 (three rows per slab)
#  axis 2 — size 4 (four columns per row)

#    slab 0               slab 1
#  ┌────────────────┐   ┌────────────────┐
#  │  0  1  2  3    │   │ 12 13 14 15    │  ← axis 1, row 0
#  │  4  5  6  7    │   │ 16 17 18 19    │  ← axis 1, row 1
#  │  8  9 10 11    │   │ 20 21 22 23    │  ← axis 1, row 2
#  └────────────────┘   └────────────────┘
#    ↑ axis 2 (4 cols)

a.shape  # (2, 3, 4)
a.ndim   # 3
a.size   # 24
```

`reshape` does not move data — it changes the shape metadata while the flat buffer stays fixed. It is nearly free. The constraint is that the total number of elements must stay the same.

```python
flat  = np.arange(12)            # (12,)
mat   = flat.reshape(3, 4)       # (3, 4)
cube  = flat.reshape(2, 2, 3)    # (2, 2, 3)
col   = flat.reshape(12, 1)      # (12, 1) column vector
row   = flat.reshape(1, 12)      # (1, 12) row vector
auto  = flat.reshape(3, -1)      # -1 means "infer this dim" → (3, 4)
```

### Axis in reductions

The `axis=` parameter tells NumPy *which dimension to collapse*. After collapsing that axis, it disappears from the output shape (unless you pass `keepdims=True`).

```python
m = np.array([[1, 2, 3],
              [4, 5, 6]])      # shape (2, 3)

m.sum()              # 21            — scalar: all axes collapsed
m.sum(axis=0)        # [5, 7, 9]    — axis 0 (rows) collapsed: shape (3,)
m.sum(axis=1)        # [6, 15]      — axis 1 (cols) collapsed: shape (2,)

m.max(axis=0)        # [4, 5, 6]    — max per column
m.mean(axis=1)       # [2. 5.]      — mean per row

# keepdims — preserves the collapsed dimension as size 1
m.sum(axis=1, keepdims=True)   # [[6], [15]]  shape (2, 1) — needed for broadcasting
```

Rule of thumb: `axis=0` collapses *down the rows* (think "per column"), `axis=1` collapses *across columns* (think "per row").

---

## Slicing — views with no data copy

NumPy basic slicing uses the standard Python slice syntax `start:stop:step`. Every basic slice returns a **view** — a different ndarray object pointing at the same data buffer with a different shape and strides descriptor.

```python
a = np.arange(10)    # [0 1 2 3 4 5 6 7 8 9]

a[2:7]               # [2 3 4 5 6]
a[::2]               # [0 2 4 6 8]   every other
a[1::2]              # [1 3 5 7 9]   odd indices
a[::-1]              # [9 8 7 6 5 4 3 2 1 0] reversed

# 2D slicing
m = np.arange(9).reshape(3, 3)
#  [[0 1 2]
#   [3 4 5]
#   [6 7 8]]

m[1:, :2]   # rows 1-end, cols 0-1:  [[3 4], [6 7]]
m[:, 1]     # all rows, col 1:       [1 4 7]
m[::2, ::2] # every other row+col:   [[0 2], [6 8]]
```

Because a slice is a view, **writing into it modifies the original**:

```python
sub = a[2:5]
sub[:] = 99
a    # [0 1 99 99 99 5 6 7 8 9]
```

Check whether two arrays share memory with `np.shares_memory(a, b)`. Check the owner with `b.base` — if `None`, the array owns its buffer; if non-`None`, it is a view of `b.base`.

---

## Fancy indexing — copies with arbitrary selection

Fancy indexing uses an array of integers or booleans as the index. It always returns a **copy**.

```python
a = np.array([10, 20, 30, 40, 50])

# integer array index
idx = np.array([0, 2, 4])
a[idx]                  # [10 30 50]

# 2D row selection
m = np.arange(12).reshape(4, 3)
m[[0, 2]]               # rows 0 and 2:  [[0 1 2], [6 7 8]]

# paired (row, col) pairs — selects specific elements
m[[0, 1, 2], [0, 1, 2]] # diagonal: [0, 4, 8]
```

**Boolean indexing** — the most common form in data pipelines:

```python
a = np.array([10, -5, 30, -2, 50])
mask = a > 0             # [True False True False True]
a[mask]                  # [10 30 50]

# inline conditions — standard idiom
a[a < 0]                 # [-5 -2]
a[(a > 0) & (a < 40)]    # [10 30] — note: & not 'and', parentheses required
a[(a < 0) | (a > 40)]    # [-5 -2 50]

# set elements in-place via boolean mask
a[a < 0] = 0             # [-5 and -2 replaced with 0]
```

Combined with `np.where` for a vectorized conditional:

```python
np.where(a > 0, a, 0)    # positive elements kept, rest zeroed
np.where(a > 0, a, -a)   # equivalent to np.abs(a)
np.where(a > 30, "high", "low")   # string output — produces object dtype, avoid in hot paths
```

---

## Broadcasting — the full rules

Broadcasting is the mechanism NumPy uses to apply operations between arrays of different shapes **without copying data**. The rules are precise and deterministic; once you internalize them you can predict any broadcast result without running code.

**Rule 1 — pad shapes from the left with 1s** until both arrays have the same number of dimensions.

**Rule 2 — any dimension of size 1 is virtually stretched** to match the other array's size in that dimension.

**If neither dimension is 1 and the sizes differ, it is an error.**

```
Example 1:
  a.shape:  (    3, 4)   → padded: (1, 3, 4)
  b.shape:  ( 2, 1, 4)
  result:   ( 2, 3, 4)   ← both 1s stretched to match

Example 2:
  a.shape:  (5, 3)
  b.shape:  (   3)       → padded: (1, 3)
  result:   (5, 3)

Example 3 — error:
  a.shape:  (5, 3)
  b.shape:  (5, 4)       → neither is 1, 3 ≠ 4 → ValueError
```

```python
# Subtract per-column mean (normalise columns)
X = np.random.randn(100, 5)   # (100, 5)
col_mean = X.mean(axis=0)     # (5,)  — right-aligns to (1, 5) → broadcasts across 100 rows
X -= col_mean                 # (100, 5) minus (5,) — fine

# Subtract per-row mean (normalise rows)
row_mean = X.mean(axis=1, keepdims=True)  # (100, 1) — keepdims is essential
X -= row_mean                              # (100, 5) minus (100, 1) — fine

# outer product via broadcasting
a = np.array([1, 2, 3])   # (3,)
b = np.array([10, 20])    # (2,)
a[:, None] + b            # (3, 1) + (2,) = (3, 2) — outer sum
# [[ 11  21]
#  [ 12  22]
#  [ 13  23]]
```

The `[:, None]` idiom (equivalently `np.newaxis`) inserts a size-1 axis. It is the single most useful broadcasting trick: convert a 1-D array into a column vector so it broadcasts against a 2-D matrix.

---

## ufuncs — element-wise with no Python overhead

A ufunc (universal function) is a C-compiled function that applies an operation element-wise to one or more arrays. All arithmetic operators, comparisons, and most math functions are ufuncs.

```python
a = np.array([1.0, 4.0, 9.0, 16.0])

np.sqrt(a)              # [1. 2. 3. 4.]
np.log(a)               # natural log
np.log2(a), np.log10(a)
np.exp(a)
np.sin(a), np.cos(a), np.tan(a)
np.abs(a)
np.sign(a)              # -1, 0, or +1
np.maximum(a, 3.0)      # element-wise max with scalar: [3. 4. 9. 16.]
np.minimum(a, 8.0)      # [1. 4. 8. 8.]
np.clip(a, 2.0, 10.0)   # clamp to [2, 10]: [2. 4. 9. 10.]
```

**The `out=` argument** — for large arrays, avoid the default allocation:

```python
result = np.empty_like(a)
np.sqrt(a, out=result)   # writes directly into result, no new buffer allocated
# in a loop processing 10 million rows, this eliminates millions of allocations
```

**Aggregation ufuncs** (reduce along axis):

```python
np.sum(a), np.prod(a)
np.min(a), np.max(a)
np.argmin(a), np.argmax(a)  # index of min/max
np.any(a > 5)               # True if any element > 5
np.all(a > 0)               # True if all elements > 0
np.cumsum(a)                # running sum: each element is sum of all up to that index
np.cumprod(a)
np.diff(a)                  # first differences: output has length n-1
```

**Vectorized comparisons:**

```python
np.isnan(a)              # True where NaN
np.isinf(a)              # True where +/-inf
np.isclose(a, b, rtol=1e-5, atol=1e-8)  # for float equality — never use ==
np.isfinite(a)           # True where not NaN and not inf
```

---

## Views vs copies — the complete picture

| Operation | View or copy? | Notes |
|-----------|--------------|-------|
| `a[2:5]` basic slice | view | strides change, data shared |
| `a.T` transpose | view | strides reordered, data shared |
| `a.reshape(n)` | view (when possible) | copy if data is non-contiguous |
| `a.ravel()` | view (when possible) | |
| `a.flatten()` | always copy | explicit contract |
| `a[[0,1,2]]` fancy int index | copy | arbitrary reorder requires new buffer |
| `a[bool_mask]` boolean mask | copy | output size not known until runtime |
| `a.copy()` | copy | explicit |
| `a.astype(dtype)` | copy (by default) | use `copy=False` only if dtype is already correct |
| `np.concatenate(...)` | copy | always new array |

### The in-place vs rebinding distinction

```python
a = np.arange(6, dtype=float)
b = a[::2]       # b is a view of a, sharing the even-indexed elements

# Case 1: in-place on a view — modifies the shared buffer
b *= 2
# a is now [0. 2. 2. 3. 4. 5.]  — elements 0, 2, 4 were doubled
#              ↑       ↑       ↑

# Case 2: rebinding — creates a new array, a unchanged
a = np.arange(6, dtype=float)
b = a[::2]
b = b * 2        # b now points to a new array; a is untouched
```

`b *= 2` is equivalent to `np.multiply(b, 2, out=b)` — it writes *through* the view. `b = b * 2` allocates a new array and rebinds the local name `b`.

### When copies sneak in and waste memory

```python
# Transpose then slice → non-contiguous view → reshape must copy
A = np.random.randn(1000, 500)
B = A.T.reshape(-1)     # A.T is a view; reshape of non-contiguous data makes a copy
B.base is None          # True — B owns its buffer, not a view of A

# Use np.ascontiguousarray() when you need to guarantee layout for C extensions
A_c = np.ascontiguousarray(A.T)   # makes a copy with C-contiguous layout
```

---

## Why vectorized beats loops: memory layout and SIMD

The three layers of speedup:

**1. No Python interpreter dispatch.** A Python bytecode loop pays ~100 ns per iteration in CPython — type checking, reference-count increment/decrement, hash lookups. For 10M elements that is 1 second of pure overhead before any arithmetic.

**2. SIMD instructions.** The Apple M2's NEON unit operates on 128-bit vectors. For `float32` that is 4 elements per instruction; for `float64`, 2. NumPy (via OpenBLAS or Accelerate on macOS) emits these instructions automatically. A single `np.sqrt()` call over 10M float64s takes ~25 ms; a loop would take ~7 s.

**3. Cache efficiency.** A flat `float64` buffer for 10M elements is 80 MB. Sequential reads stream through L2/L3 in large cache lines. A Python list of 10M integers is ~280 MB of scattered objects — every read is a cache miss.

```python
import time, numpy as np

n = 10_000_000
a = np.random.rand(n)

# Python loop
t0 = time.perf_counter()
result = [x**0.5 for x in a.tolist()]
print(f"loop:     {time.perf_counter() - t0:.2f}s")

# NumPy ufunc
t0 = time.perf_counter()
result = np.sqrt(a)
print(f"np.sqrt:  {time.perf_counter() - t0:.4f}s")
# loop: ~6–8s  |  np.sqrt: ~0.02–0.05s  →  ~150–300x
```

**`np.vectorize` is not SIMD.** It wraps a Python function and applies it element-wise with reduced overhead — but it is still calling a Python function per element. It is sometimes *slower* than a plain loop due to the wrapper. Use it only for API compatibility, not performance.

**Numba is the escape hatch.** When you genuinely need a loop — graph traversal, recursive logic, anything that cannot be expressed as ufunc composition — annotate it with `@numba.njit`. Numba JIT-compiles to native code including SIMD. But first, try expressing the computation with NumPy: most "un-vectorizable" problems have a vectorized form.

---

## Practical patterns

**Z-score normalization (per column):**

```python
X = np.random.randn(1000, 10)
X_norm = (X - X.mean(axis=0)) / X.std(axis=0)
# X.mean(axis=0) is (10,) → broadcasts to (1000, 10) by rule 1
```

**Pairwise Euclidean distances (no loops):**

```python
# Given points X of shape (n, d), compute all n×n distances
# ||xi - xj||^2 = ||xi||^2 + ||xj||^2 - 2 * xi·xj
X = np.random.randn(100, 3)
sq = np.sum(X**2, axis=1)              # (100,)
dists2 = sq[:, None] + sq[None, :] - 2 * X @ X.T   # (100, 100)
dists2 = np.maximum(dists2, 0)         # numerical safety: clip negative near-zeros
dists = np.sqrt(dists2)
```

**One-hot encoding:**

```python
labels = np.array([0, 2, 1, 0, 2])  # class indices
n_classes = 3
ohe = (labels[:, None] == np.arange(n_classes)[None, :]).astype(np.float32)
# [[1 0 0]
#  [0 0 1]
#  [0 1 0]
#  [1 0 0]
#  [0 0 1]]
```

**Running mean over a sliding window:**

```python
def rolling_mean(a, w):
    cs = np.concatenate([[0], np.cumsum(a)])
    return (cs[w:] - cs[:-w]) / w
```

---

## Debugging NumPy

### Shape mismatches

```
ValueError: operands could not be broadcast together with shapes (5,3) (3,5)
```

The shapes do not align from the right. Fix: transpose or reshape.

```python
a.shape    # (5, 3)
b.shape    # (3, 5)
a + b      # error — right-aligned: (5,3) vs (3,5), 3≠5 or 5≠3
a + b.T    # ok: (5,3) + (5,3)
```

```
ValueError: operands could not be broadcast together with shapes (100,) (100,5)
```

You want to subtract a (100,) column vector from each column of (100,5), but NumPy right-aligns (100,) as (1,100)…(100,5) — sizes 100 and 5 don't match. Fix:

```python
v = np.arange(100)            # (100,)
X = np.random.randn(100, 5)
X - v         # error
X - v[:, None]  # ok — v[:, None] is (100,1) → broadcasts to (100,5)
```

### Broadcasting surprises

The most insidious: you think you're subtracting a scalar but you're doing an outer product.

```python
a = np.array([1.0, 2.0, 3.0])   # (3,)
b = np.array([10.0, 20.0])      # (2,)
a - b       # error — good, at least it's loud
a[:, None] - b   # (3, 2) outer subtraction — this is silent and correct if intended
```

Float comparison after broadcasting:

```python
a = np.linspace(0, 1, 11)   # [0.0, 0.1, 0.2, ..., 1.0]
a == 0.3                    # [False ... False False False ...]  all False due to float repr
np.isclose(a, 0.3)          # [False ... True ... False]  correct
```

### Accidental copies losing in-place writes

```python
def center(X):
    X = X - X.mean(axis=0)   # rebinds local X — caller's array untouched
    return X                  # fine IF caller uses the return value

data = np.random.randn(100, 5)
center(data)                  # result discarded — data unchanged
data = center(data)           # correct usage with this signature
```

Alternatively, modify in-place:

```python
def center_inplace(X):
    X -= X.mean(axis=0)       # modifies caller's buffer — no copy created
```

### Diagnosing unexpected object arrays

```python
a = np.array([1, 'two', 3.0])
a.dtype    # dtype('O') — mixed types → object array — all vectorization lost

b = np.array([[1, 2], [3, 4, 5]])   # ragged list
b.dtype    # dtype('O') — jagged dimensions → object array of lists
b.shape    # (2,) — not (2, 3) as you might expect

# assertion in production code:
assert X.dtype.kind in ('f', 'i', 'u'), f"non-numeric dtype: {X.dtype}"
# 'f' = float, 'i' = signed int, 'u' = unsigned int
```

---

## Checkpoint

You are ready to move forward when you can, without looking anything up:

1. Explain in two sentences why `dtype=object` nullifies NumPy's performance advantage.
2. Given `X.shape = (100, 5)`, predict the shape of `X.mean(axis=0)` and `X.mean(axis=1, keepdims=True)`.
3. State the two broadcasting rules and predict the output shape of `(3, 1)` + `(1, 4)`.
4. Write a one-line z-score normalization for a `(n, d)` feature matrix (per-column mean and std).
5. Distinguish view from copy for: a basic slice, `a.T`, a boolean mask, and `np.concatenate`.
6. Explain why `b *= 2` on a view modifies the original but `b = b * 2` does not.
7. Describe the `[:, None]` idiom and say what it does to an array of shape `(n,)`.
8. State one situation where `np.vectorize` does not give a speedup over a plain loop, and name the alternative.
9. Write the one-line pairwise squared distance formula for a `(n, d)` matrix using only broadcasting and `@`.

-> Next: **pandas: Wrangling & Cleaning** — arrays get labels and a time index, and the DataFrame index is the thing you must understand before groupby or merge makes sense.
