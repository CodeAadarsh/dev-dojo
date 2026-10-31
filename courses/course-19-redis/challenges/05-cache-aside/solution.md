# Solution: Cache-Aside Pattern

## The pattern in full

Cache-aside (lazy-loading) follows a simple three-step decision tree on every read:

```
READ product:1
  │
  ├─ GET dojo:cache:product:1
  │         │
  │    ┌────┴─────┐
  │   HIT        MISS
  │    │          │
  │  return     HGET dojo:sot product:1   ← read from source
  │  cached       │
  │  value      SET dojo:cache:product:1 <value> EX 60
  │               │
  │             return value
  └──────────────────────────────────────────────────────
```

The write path is always source-of-truth only (cache is never written directly on mutation in cache-aside). When the source changes, the cache entry expires on its TTL and is lazily refreshed on the next miss.

## Step-by-step walkthrough

### Step 1: Confirm the source of truth is intact

```bash
docker exec dojo-redis redis-cli HGETALL dojo:sot
```

Output:
```
1) "product:1"
2) "Widget|9.99|tools"
3) "product:2"
4) "Gadget|14.99|electronics"
5) "product:3"
6) "Doohickey|4.99|misc"
```

### Step 2: Miss path for product 1

Check cache:

```bash
docker exec dojo-redis redis-cli EXISTS dojo:cache:product:1
# -> 0  (miss)
```

Read from source:

```bash
docker exec dojo-redis redis-cli HGET dojo:sot product:1
# -> "Widget|9.99|tools"
```

Populate cache with TTL:

```bash
docker exec dojo-redis redis-cli SET dojo:cache:product:1 "Widget|9.99|tools" EX 60
# -> OK
```

### Step 3: Repeat for products 2 and 3

```bash
docker exec dojo-redis redis-cli SET dojo:cache:product:2 "Gadget|14.99|electronics" EX 60
docker exec dojo-redis redis-cli SET dojo:cache:product:3 "Doohickey|4.99|misc" EX 60
```

### Step 4: Hit path — demonstrate a cache hit

```bash
# Check: 1 = hit
docker exec dojo-redis redis-cli EXISTS dojo:cache:product:1
# -> 1

# Serve from cache (no HGET call needed)
docker exec dojo-redis redis-cli GET dojo:cache:product:1
# -> "Widget|9.99|tools"

# Remaining TTL
docker exec dojo-redis redis-cli TTL dojo:cache:product:1
# -> 57  (or similar, counting down from 60)
```

### Step 5: Verify

```bash
bash courses/course-19-redis/challenges/05-cache-aside/verify.sh
```

## Why `SET key value EX n` and not `SET key value` + `EXPIRE key n`

This is a critical atomicity detail. Using two commands:

```bash
SET dojo:cache:product:1 "Widget|9.99|tools"    # command 1
EXPIRE dojo:cache:product:1 60                   # command 2
```

introduces a race condition: if the process crashes or is killed between the two commands, the key exists *without a TTL* — it lives forever, serving potentially stale data indefinitely.

The `SET key value EX n` form is atomic — the expiry is set in the same operation. Always prefer it.

Alternatively, `SET key value PX n` accepts milliseconds (useful for sub-second TTLs in rate limiters).

For conditional cache population (set only if the key doesn't already exist — prevents a thundering herd from overwriting):

```bash
# SET key value EX n NX  — only set if key does not exist
docker exec dojo-redis redis-cli SET dojo:cache:product:1 "Widget|9.99|tools" EX 60 NX
```

Returns `OK` on success, `(nil)` if the key already exists (another process populated it first). This is the cache-aside version used in distributed systems to avoid multiple processes racing to populate the same key.

## Encoding and memory efficiency

When you do `SET dojo:cache:product:1 "Widget|9.99|tools"`, Redis stores the value as a **raw string** (type: string, encoding: embstr for values ≤ 44 bytes, or raw for longer). Check with:

```bash
docker exec dojo-redis redis-cli OBJECT ENCODING dojo:cache:product:1
# -> "embstr"  (for short strings — stored inline in the robj structure, one allocation)
```

`embstr` strings are slightly faster to read and use less memory than `raw`. For cache values that are consistently ≤ 44 bytes, this is free optimization.

For richer structured values you might serialize to JSON:

```bash
docker exec dojo-redis redis-cli SET dojo:cache:product:1 \
    '{"name":"Widget","price":9.99,"category":"tools"}' EX 60
```

Or use a Redis hash per cached object (more memory but individual field access):

```bash
docker exec dojo-redis redis-cli HSET dojo:cache:product:1 \
    name Widget price 9.99 category tools
docker exec dojo-redis redis-cli EXPIRE dojo:cache:product:1 60
```

The string approach is more common and slightly more memory-efficient for small objects.

## Thundering herd

When a high-traffic cache key expires simultaneously for many requests (cold start, TTL expiry under load), every goroutine or thread that misses the cache fires a DB query at the same instant. This is the **thundering herd** (also called cache stampede).

Mitigations in order of complexity:

1. **TTL jitter**: instead of `EX 60` for all products, use `EX $((60 + RANDOM % 20))` to spread expiry. Eliminates synchronized expiry patterns.

2. **SET NX**: only the first process to miss actually populates the cache. Others that arrive before the key exists also miss and query the DB, but `SET ... NX` ensures only one write wins. The DB still takes multiple concurrent reads, but the write contention is eliminated.

3. **Lock-based population**: use a Redis distributed lock (SETNX on a lock key) so only one process populates the cache while others wait. More complex, overkill for most cases.

4. **Probabilistic early expiration (XFetch)**: before the TTL hits zero, occasionally pre-populate the cache in a background task. The algorithm intentionally refreshes slightly before expiry proportional to how expensive the cache miss is.

For the SAP use case (product catalogue, relatively infrequent access, moderate traffic): TTL jitter + NX is sufficient and requires no additional infrastructure.

## Debugging cache-aside

**Key not found after SET:**

```bash
docker exec dojo-redis redis-cli DEBUG SLEEP 0    # connection sanity check
docker exec dojo-redis redis-cli OBJECT FREQ dojo:cache:product:1   # access frequency (LFU mode)
docker exec dojo-redis redis-cli DEBUG OBJECT dojo:cache:product:1  # serialized length, LRU clock
```

**Key was evicted prematurely:**

Check eviction stats:

```bash
docker exec dojo-redis redis-cli INFO stats | grep evicted_keys
```

If `evicted_keys` is non-zero, Redis is hitting `maxmemory` and evicting your cache entries. Solutions: increase `maxmemory`, reduce value sizes, or accept eviction as intended (if using `allkeys-lru`).

**TTL returned -1 (no expiry) instead of > 0:**

The `SET key value` form was used without `EX`. Fix by either:
- `SET key value EX 60` (atomic, preferred)
- `EXPIRE key 60` (adds expiry to existing key, not atomic with the SET)

Check:
```bash
docker exec dojo-redis redis-cli TTL dojo:cache:product:1
# -1 = no expiry
# -2 = key does not exist
# N  = N seconds remaining
```
