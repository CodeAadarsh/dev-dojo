# Solution — Cache to Hit SLO

```python
from collections import OrderedDict
from typing import Callable, Dict, Any, Optional


def process_requests(
    trace: list,
    expensive_fn: Callable[[str], Any] = expensive_compute,
    max_cache_size: Optional[int] = None,
) -> Dict[str, Any]:
    results: Dict[str, Any] = {}

    if max_cache_size is None:
        # Unbounded: every unique key is computed exactly once
        for key in trace:
            if key not in results:
                results[key] = expensive_fn(key)
        return results

    # Bounded LRU via OrderedDict
    # Invariant: head = LRU entry, tail = MRU entry
    lru: OrderedDict = OrderedDict()
    for key in trace:
        if key in lru:
            lru.move_to_end(key)          # cache hit: promote to MRU
            results[key] = lru[key]
        else:
            value = expensive_fn(key)     # cache miss: compute
            lru[key] = value
            results[key] = value          # record in results BEFORE any eviction
            if len(lru) > max_cache_size:
                lru.popitem(last=False)   # evict LRU entry
    return results
```

Apply and verify:

```bash
cd ~/.kube-dojo-work/03-cache-to-hit-slo
.venv/bin/pytest tests/ -v
bash courses/course-29-performance-engineering/challenges/03-cache-to-hit-slo/verify.sh
```

## Why each piece is correct

**Unbounded case: plain dict.** `if key not in results: results[key] = expensive_fn(key)` is all that's needed. The first occurrence of each unique key computes and stores the result; every subsequent occurrence reads from the dict in O(1). Total calls = number of unique keys.

**Bounded case: `collections.OrderedDict`.**

Python's `OrderedDict` maintains insertion order and exposes two operations that make LRU trivial:
- `move_to_end(key)` — moves an existing key to the tail (most-recently-used end).
- `popitem(last=False)` — removes and returns the head item (least-recently-used end).

The invariant: the head is always the LRU entry; the tail is the MRU entry.

**`results` is separate from `lru`.** We record `results[key] = value` _before_ `popitem` runs. After eviction, if that key appears again later in the trace, it will be recomputed and written to `results` again with the same value (since `expensive_fn` is deterministic). `results` always contains the correct {key: value} pair for every unique key seen — independent of whether the key is currently in the bounded cache.

## The `functools.lru_cache` shortcut

Python ships LRU caching in the standard library:

```python
import functools

def process_requests(trace, expensive_fn=expensive_compute, max_cache_size=None):
    cached = functools.lru_cache(maxsize=max_cache_size)(expensive_fn)
    results = {}
    for key in trace:
        results[key] = cached(key)
    return results
```

`functools.lru_cache(maxsize=None)` is an unbounded cache; `maxsize=N` gives exact LRU(N) semantics that match the manual `OrderedDict` implementation. This is the idiomatic Python answer in production code. The manual version is here to show you what `lru_cache` does under the hood — understanding it lets you implement the same pattern in Go, Java, or Rust without a standard-library shortcut.

## Cache hit ratio and SLO math

With 50 unique keys and 1 000 requests:
- **Unbounded cache**: 50 compulsory misses, 950 hits → 95% hit rate → 50 calls to `expensive_fn`.
- **LRU(20), Zipf traffic**: the top 20 keys account for ~80% of requests. After warmup they stay in cache most of the time, though cold keys occasionally evict hot ones and trigger recomputes. In practice: ~200–350 calls (well under the 400-call target and far below the 1 000 no-cache baseline).

In SLO terms: if `expensive_fn` costs 50 ms, uncached p99 = 50 ms (every request pays). With the unbounded cache, 95% of requests return in ~0.1 ms (dict lookup); only the 50 initial misses pay 50 ms. The p99 drops from 50 ms to ~0.5 ms — well under the 500 ms SLO.

## LRU eviction walkthrough — the test case

Trace `[a, b, c, a]` with `max_cache_size=2`:

| Step | Key | Cache before | Action | Cache after | `expensive_fn` calls |
|------|-----|--------------|--------|-------------|----------------------|
| 1 | a | {} | miss → compute, insert | {a} | 1 |
| 2 | b | {a} | miss → compute, insert | {a→LRU, b→MRU} | 2 |
| 3 | c | {a, b} full | miss → compute, insert → evict LRU=a | {b→LRU, c→MRU} | 3 |
| 4 | a | {b, c} | miss (evicted) → compute, insert → evict LRU=b | {c→LRU, a→MRU} | 4 |

Total calls: 4. The verifier asserts ≥ 3 (the eviction at step 3 forces a re-compute at step 4), confirming that your LRU actually evicts entries rather than silently growing.
