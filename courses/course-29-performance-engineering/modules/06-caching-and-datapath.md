# Caching & Data-Path Tuning

> **Module 06 · Course 29** — The fastest work is the work you never do. This module is about the full stack of places you can skip work: CPU caches, in-process memoization, write batching, zero-copy IO, N+1 elimination, and data-layout-driven locality. None of it requires heroics; most of it is reading a flame graph and asking "did I have to allocate that?"

The distinction between a 5ms p99 and a 50ms p99 usually lives in this module's topics, not in algorithmic complexity.

---

## Cache layers and hit-ratio math

Every system has multiple cache layers. Name them from hottest (fastest) to coldest (slowest), and you can reason about where a request's "saved work" actually lives.

```
      ┌─────────────────────────────────────────────────────────────┐
      │  L1 d-cache  ~4 cycles  (64 KB, per core)                   │
      │  L2 cache    ~12 cycles (256 KB – 1 MB, per core)           │
      │  L3 cache    ~40 cycles (6–32 MB, shared)                   │
      │  DRAM        ~100–200 ns (~300 cycles)                      │
      │  local SSD   ~100 µs                                        │
      │  in-process LRU (Redis, Memcached)  ~0.1–1 ms              │
      │  network cache (CDN edge)  5–50 ms                          │
      │  origin DB / upstream API  10–500 ms                        │
      └─────────────────────────────────────────────────────────────┘
```

A cache miss at any layer falls through to the next. Understand *which* layer you're optimizing before benchmarking.

### Hit-ratio math

For a two-level cache (hot in-process LRU → cold Postgres):

```
E[latency] = hr₁ × L₁ + (1 − hr₁) × hr₂ × L₂ + (1 − hr₁) × (1 − hr₂) × L₃

hr₁ = in-process hit ratio (e.g. 0.80)
hr₂ = Redis hit ratio (e.g. 0.95)
L₁  = in-process lookup latency (0.01 ms)
L₂  = Redis latency (0.5 ms)
L₃  = Postgres latency (20 ms)

E[latency] = 0.80 × 0.01 + 0.20 × 0.95 × 0.5 + 0.20 × 0.05 × 20
           = 0.008 + 0.095 + 0.200
           = 0.303 ms   ← most requests see sub-ms
```

Doubling the in-process hit ratio from 80% to 90% in this example reduces E[latency] from 0.303 ms to about 0.155 ms — a 2× improvement without touching the DB. Hit ratio is not a vanity metric; it directly controls expected latency.

**How to measure hit ratio:**
- In-process LRU: `cache_info()` on Python `functools.lru_cache`, or custom counters.
- Redis: `redis-cli info stats | grep -E 'keyspace_hits|keyspace_misses'` → compute `hits / (hits + misses)`.
- CDN: your provider's cache analytics page or `x-cache: HIT` header sampling.

---

## Memoization

Memoization is a cache whose key is the function's input tuple. It's the right pattern when:

1. The function is **pure** (same inputs → same output, no side effects).
2. The input space is small enough to fit in memory, or an LRU eviction policy keeps it bounded.
3. The call is **frequent** and the compute or IO cost is non-trivial.

```python
import functools
import time

@functools.lru_cache(maxsize=1024)
def compute_score(user_id: int, model_version: str) -> float:
    # expensive DB + ML call — memoized per (user_id, model_version)
    ...

# invalidation: lru_cache doesn't support per-key invalidation
# → use cachetools.TTLCache for TTL-based expiry
from cachetools import TTLCache, cached

_cache = TTLCache(maxsize=1024, ttl=60)  # 60-second TTL

@cached(_cache)
def get_user_features(user_id: int) -> dict:
    ...
```

**Gotcha: memoizing mutable return values.** If the caller mutates the returned dict, every future caller sees the mutation because `lru_cache` returns the same object. Return immutable types (tuples, frozensets) or deepcopy on the way out. Or just use `cachetools` which has a simpler mental model.

**Distributed memoization (Redis):** the key should encode everything that affects the result. Miss the model version in the key and you'll serve stale predictions after a rollout. Use a schema like `{service}:{function}:{stable_hash(args)}` and store the hash in the key for auditability.

---

## Batching and coalescing

A 1ms-per-call DB query that's called 1000 times in a tight loop is a 1-second stall. Batching turns N round-trips into one:

### Write batching

```python
# before: N inserts, N round-trips
for event in events:
    cursor.execute("INSERT INTO events VALUES (%s, %s)", (event.id, event.ts))

# after: one round-trip, one server-side operation
cursor.executemany(
    "INSERT INTO events VALUES (%s, %s)",
    [(e.id, e.ts) for e in events]
)
# or, for Postgres, use COPY for bulk loads (10–100× faster than INSERT)
```

### Read coalescing (DataLoader pattern)

In a GraphQL or REST service that resolves N objects, each triggering a DB lookup:

```python
# DataLoader — collects keys over a tick, issues one batched query
from aiodataloader import DataLoader

async def batch_load_users(user_ids):
    rows = await db.fetch("SELECT * FROM users WHERE id = ANY($1)", user_ids)
    by_id = {r["id"]: r for r in rows}
    return [by_id.get(uid) for uid in user_ids]

user_loader = DataLoader(batch_load_users)

# each resolver calls:
user = await user_loader.load(user_id)
# all loads within the same asyncio tick are batched into one DB round-trip
```

Coalescing is the read side of batching: multiple callers asking for data within the same scheduler tick are merged into one upstream request. This is essential in async architectures where a single HTTP request fans out to hundreds of sub-resolvers.

---

## Reducing allocations and copies

### Why allocations matter

Every object allocation in a GC language:
1. Bumps the allocator pointer (cheap — nanoseconds for young-gen bump allocation).
2. Gets scanned by the GC on every minor cycle.
3. May survive and be promoted to old-gen, making future major GCs slower.

In a hot path running 10k times/second, allocating a 100-element list each call = 1M new objects/second. GC pressure alone can add 5–20ms of stop-the-world latency to your p99.

### Object reuse patterns

```python
# instead of allocating a new list each call:
_RESULT_BUFFER: list = []

def process_batch(items):
    _RESULT_BUFFER.clear()
    for item in items:
        _RESULT_BUFFER.append(transform(item))
    return _RESULT_BUFFER   # caller must not store this reference across calls

# or use a bytearray/memoryview for byte-level work:
def copy_with_header(src: bytes, header: bytes) -> memoryview:
    buf = bytearray(len(header) + len(src))
    buf[:len(header)] = header
    buf[len(header):] = src
    return memoryview(buf)   # zero-copy slice
```

### String concatenation in loops

```python
# O(n²) — each += allocates a new string
result = ""
for s in parts:
    result += s

# O(n) — one allocation
result = "".join(parts)
```

In Python, `str.join` is the canonical fix. In Java/Kotlin, `StringBuilder` or `StringJoiner`. In Go, `strings.Builder`.

---

## N+1 elimination

N+1 is the silent killer of ORM-heavy backends. The pattern:

1. Fetch N parent objects in one query.
2. For each parent, issue one child query → N more queries.

At scale, N+1 that was imperceptible at 10 rows becomes the dominant cost at 10k.

### Detection

- **Slow query log:** turn on `log_min_duration_statement = 100` in Postgres and look for the same query appearing hundreds of times in a short window.
- **ORM debug logging:** `SQLALCHEMY_ECHO=true`, Django `DEBUG=True` (check `django.db.connection.queries`), Hibernate SQL logging.
- **APM traces:** Datadog, Jaeger, or even a simple OpenTelemetry trace will show the N identical DB spans as a waterfall.

### Fix

```python
# SQLAlchemy — before: lazy load triggers N queries
for order in session.query(Order).all():
    print(order.customer.name)   # each .customer issues SELECT customer WHERE id=?

# after: eager load with JOIN, 1 query
orders = (
    session.query(Order)
    .options(joinedload(Order.customer))
    .all()
)
for order in orders:
    print(order.customer.name)   # already in memory

# for large collections, prefer selectinload (avoids cartesian product):
.options(selectinload(Order.items))
```

---

## Zero-copy and buffer reuse

Copying bytes through multiple buffers is invisible overhead until you profile it. In a web server serving a 1 MB file:

```
disk read → kernel page cache → user-space read() buffer → write() → kernel send buffer → NIC
                                   ^─────── unnecessary copy ───────^
```

`sendfile(2)` (or `os.sendfile` in Python, `TransferTo` in Java NIO) skips the user-space copy entirely, moving data directly from page cache to the socket buffer via DMA. For large static files, `sendfile` typically doubles throughput.

In Python with asyncio / aiofiles, use `aiohttp.FileResponse` or FastAPI's `FileResponse` — both use `sendfile` under the hood on Linux.

### Memory-mapped IO

For read-heavy in-process access to large files (ML model weights, embedding tables):

```python
import mmap, struct

with open("embeddings.bin", "rb") as f:
    mm = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
    # read a 128-float vector at byte offset k
    floats = struct.unpack_from("128f", mm, offset=k * 128 * 4)
    # kernel maps file pages into address space; no explicit read() call needed
```

The kernel brings pages into RAM on access (demand paging). The OS page cache is the cache; you don't maintain a separate one. Access patterns that are sequential get OS read-ahead for free.

---

## Data locality

The CPU L1 cache line is 64 bytes. Accessing field `y` in a struct causes the whole 64-byte line containing `y` to be loaded. If you touch `x` two lines away, that's another cache miss.

### Struct-of-Arrays vs Array-of-Structs

```python
# Array-of-Structs — poor locality when scanning one field
class Point:
    x: float; y: float; z: float   # 24 bytes; adjacent access of .x on N points = N cache misses

points = [Point(...) for _ in range(100_000)]
xs = [p.x for p in points]   # 100k objects, 100k pointer dereferences

# Struct-of-Arrays — excellent locality for field-wise scans
import numpy as np
xs = np.empty(100_000)
ys = np.empty(100_000)
zs = np.empty(100_000)
# xs is one contiguous block; iterating it is one sequential DRAM read with full prefetch
```

For analytical workloads (aggregations, filtering) over large datasets, column-oriented layout (NumPy arrays, Arrow, Parquet) is not just a file format choice — it is a cache-locality optimization. Accessing a column in Arrow is ~10–50× faster than row-oriented for pure scan workloads.

### Database-level locality

- Postgres `CLUSTER tbl USING idx` rewrites table in index order — sequential scans on that index become sequential DRAM reads.
- Partial indexes (`CREATE INDEX ON orders (id) WHERE status = 'pending'`) keep hot data in a small, cache-friendly index.
- Covering indexes eliminate heap fetches entirely for frequently scanned query shapes.

---

## Debugging Caching & Data-Path Issues

### Symptom → Cause → Fix

| Symptom | Likely cause | Diagnosis | Fix |
|---------|-------------|-----------|-----|
| Cache hit ratio below 60%; latency high but DB isn't slow | Cache is too small; working set > cache capacity; or key is missing a dimension (stale key design) | `cache_info().currsize` vs `maxsize`; plot hit rate over time; log a sample of misses to see key pattern | Increase `maxsize` or switch to an external cache (Redis) for shared state; audit key construction |
| Thundering herd after a deploy or TTL expiry | Cache stampede — all workers miss simultaneously and pile into the DB | Correlate DB query spike with deploy timestamp; look for `N × identical queries` within < 100ms | Probabilistic early re-computation (refresh cache at `TTL × random(0.8, 1.0)`) or use a mutex/singleflight pattern so only one goroutine/thread recomputes per key |
| Slow API call shows 50+ identical `SELECT` in ORM debug log | N+1 — lazy loading without eager load configured | `SQLALCHEMY_ECHO=true` or `django.db.connection.queries` shows repeated single-row lookups | Add `joinedload` / `selectinload`; or raw SQL with `IN` clause |
| High GC frequency; p99 spikes every few seconds | Excessive allocation in hot path; short-lived objects dominating GC | Python: `tracemalloc` + `tracemalloc.take_snapshot()`; Java: `-Xlog:gc*` + JFR allocation profiler | Reuse objects; replace list/dict literals in tight loops with pre-allocated buffers; use slots in dataclasses |
| CPU is not the bottleneck but throughput is low; `perf` shows many L3 cache misses | Poor data locality — random access pattern, AoS layout, or pointer chasing | `perf stat -e cache-misses,cache-references` — if miss rate > 5%, locality is the bottleneck | Switch to SoA layout; sort data before batch processing; use columnar structures (NumPy, Arrow) |
| File-serving latency spikes on large responses | Extra copy in user space; no `sendfile` | `strace -e trace=read,write` — if you see a `read()` followed by `write()` for the same FD, you're copying | Use `FileResponse` (FastAPI) / `StaticFiles` or explicit `os.sendfile()`; verify with `strace` |

> **War story.** A Kafka consumer service at SAP was using ~3 GB of heap for what should have been a 200 MB workload. Profiling with `async-profiler` and `jmap -histo` revealed a single JSON deserialization path that created a new `HashMap<String, Object>` for every message — 50k messages/minute, each object surviving to old-gen because it was handed to a downstream processor that held a reference just long enough to trigger promotion. The fix was a custom Jackson deserializer that reused a pre-allocated POJO pool via `ObjectReader.readValue` into pre-existing objects. Heap dropped to 250 MB, major GC pauses went from 800ms every 3 minutes to essentially zero. The lesson: allocation problems don't present as "slow code" — they present as mysterious periodic latency spikes that look like CPU pressure until you read the GC log.

---

## Checkpoint

You're ready for the challenges when you can, without looking anything up:

1. Given hit ratios and latencies for a two-level cache, compute the expected mean latency for a request.
2. Explain why a Redis hit ratio of 95% sounds great but can still hide a catastrophic 5% that dominates cost.
3. Write the Python idiom for bounded-TTL memoization using `cachetools.TTLCache` and state the gotcha with mutable return values.
4. Describe the DataLoader pattern in one paragraph and name the problem it solves.
5. Explain the cache stampede failure mode and two strategies to prevent it.
6. Given a SQLAlchemy query with a known N+1, add the correct `options()` call and explain why `selectinload` is preferred over `joinedload` for large collections.
7. Explain, with a concrete byte-level diagram, why `sendfile` is faster than `read() + write()` for serving files.
8. Describe the SoA vs AoS trade-off and when you'd choose each.
9. Name the exact command to measure L3 cache miss rate on Linux.

➡ Next up: **Capacity Planning & Cost** — turning load-test numbers into an instance count you'll actually be comfortable with.
