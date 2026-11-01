# Cache to Hit SLO

Your service's p99 latency is 4.2 seconds. The SLO is 500 ms. Profiling reveals the culprit: an expensive downstream call is made for **every** request, including duplicate keys that arrive multiple times per second. A request trace shows 1 000 calls but only 50 unique keys — 950 of those calls are wasted.

Your task: add a cache layer to `process_requests` so repeated keys avoid the expensive call, and verify that the total call count drops below the target.

## Context

`setup.sh` plants a starter project in your work directory:

```
~/.kube-dojo-work/03-cache-to-hit-slo/
├── cache_optimizer.py       # expensive_compute + process_requests stub
└── tests/
    └── test_cache_visible.py   # visible correctness tests
```

## Prerequisites

```bash
cd ~/.kube-dojo-work/03-cache-to-hit-slo
python3 -m venv .venv && . .venv/bin/activate
pip install pytest
```

## Mission

Implement `process_requests(trace, expensive_fn, max_cache_size=None)` in `cache_optimizer.py`:

| Argument | Type | Meaning |
|----------|------|---------|
| `trace` | `list[str]` | Ordered sequence of request keys (may contain repeats) |
| `expensive_fn` | `Callable[[str], Any]` | Deterministic function to call — same key always returns same value |
| `max_cache_size` | `int \| None` | `None` = unbounded cache; integer = LRU eviction on overflow |

**Returns** `dict[str, Any]` — one entry per unique key in `trace`, mapping key → computed result.

### Part 1 — unbounded cache (simple dict)

Use a plain dict. Every unique key should result in exactly **one** call to `expensive_fn`. The verifier asserts total calls ≤ 50 for a trace with 50 unique keys.

### Part 2 — bounded LRU cache

When `max_cache_size` is set, implement **LRU (Least Recently Used)** eviction: when the cache is full and a new key arrives, evict the entry that was accessed least recently.

`collections.OrderedDict` is your friend here: `move_to_end(key)` promotes a key to MRU position; `popitem(last=False)` evicts the LRU entry (the head).

The verifier asserts total calls ≤ 200 for a Zipf-distributed trace of 1 000 requests over 50 unique keys with `max_cache_size=20`.

## Target state (what the verifier checks)

1. **Correctness** — `result[key] == expensive_fn(key)` for every unique key in the trace.
2. **Unbounded call count** — `total_calls ≤ 50` (one per unique key, 50 unique keys).
3. **Bounded LRU call count** — `total_calls ≤ 400` (cache_size=20, 50 unique keys, Zipf traffic; no-cache baseline = 1000 calls; correct LRU makes ~200–350).

## Verify

```bash
bash courses/course-29-performance-engineering/challenges/03-cache-to-hit-slo/verify.sh
```
