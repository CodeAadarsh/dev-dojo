# Caching & Performance

> **Module 03 · Course 10** — A cache is a lie that's faster than the truth. Understanding when to tell it, how long to maintain it, and what happens when a thousand clients simultaneously discover the lie has expired is the difference between a cache that scales and one that destroys your database at exactly the worst moment.

---

## Cache-Aside, Read-Through, Write-Through

Three fundamental patterns. Every caching system you build is a variant of one.

### Cache-aside (lazy loading)

The application owns the cache logic. The cache is a side-structure; the database remains the source of truth.

```
Read path:
  1. Check cache → hit: return value
                 → miss: fetch from DB, write to cache, return value

Write path:
  1. Write to DB
  2. DELETE the cache entry — do NOT write the new value to the cache
```

```python
def get_product(product_id: str) -> dict:
    key = f"product:{product_id}"
    cached = redis.get(key)
    if cached:
        return json.loads(cached)

    product = db.query("SELECT * FROM products WHERE id = %s", [product_id])
    if product:
        redis.setex(key, 300, json.dumps(product))  # TTL: 5 minutes
    return product

def update_product(product_id: str, data: dict) -> None:
    db.execute("UPDATE products SET ... WHERE id = %s", [product_id])
    redis.delete(f"product:{product_id}")  # invalidate, not update
```

**Why invalidate instead of update?** If two writes race (W1 then W2), the cache update from W1 may arrive after W2's DB write, leaving a permanently stale value. Deleting the entry forces the next read to re-fetch the authoritative DB value.

**When to use it:** Most OLTP read patterns. Simple, explicit, works with any cache layer. Downside: the first read after a miss (or cold start) hits the DB — the thundering herd risk under high concurrency.

### Read-through

The cache sits in front of the database. The application only calls the cache; on a miss the cache itself fetches from the DB.

```
Application → Cache layer → DB (on miss only)
Application → Cache layer    (on hit)
```

```python
# With a decorator-based cache library (e.g. aiocache, dogpile.cache)
@cache(ttl=300, key="product:{product_id}")
def get_product(product_id: str) -> dict:
    return db.query("SELECT * FROM products WHERE id = %s", [product_id])
```

Downside: harder to control cache invalidation granularly; the framework owns the write-back path.

### Write-through

Every write goes to cache **and** DB together, synchronously. The cache is always warm; reads always hit.

```
Write: Application → Cache (write) → DB (write, same operation or immediate sequel)
Read:  Application → Cache          (always hits; no miss)
```

```python
def update_user_profile(user_id: str, data: dict) -> None:
    db.execute("UPDATE users SET ... WHERE id = %s", [user_id])
    redis.setex(f"user:{user_id}", 3600, json.dumps(data))
```

**When to use it:** High read-to-write ratio, expensive miss (user session data, feature flags, reference data). Downside: writes are slower (two round-trips); if the cache write fails after the DB write, you have stale cache until TTL expires.

### Write-behind (write-back)

Write to cache immediately; write to DB asynchronously. Used for write-heavy workloads (game scores, real-time metrics). Risk: data loss if the cache fails before the async flush completes. Rarely appropriate for financial data.

```
┌──────────────────────────────────────────────────────────┐
│ Pattern        │ Miss latency │ Write latency │ Staleness │
├──────────────────────────────────────────────────────────┤
│ Cache-aside    │ High (DB)    │ DB only       │ Possible  │
│ Read-through   │ High (DB)    │ DB only       │ Possible  │
│ Write-through  │ Never misses │ DB + cache    │ None      │
│ Write-behind   │ Never misses │ Cache only    │ Eventual  │
└──────────────────────────────────────────────────────────┘
```

---

## Redis Data Structures

Redis is not just a key-value store. Picking the right data structure gives you atomicity, ordering, and expiry for free.

### Strings

Use for: counters, serialized JSON objects, distributed locks, simple flags.

```bash
SET user:42:session "eyJhb..." EX 3600          # session with TTL
INCR rate:api:user:42:2025-01-01:14             # atomic counter for rate limiting
SETNX lock:payment:order:99 "worker-1"          # distributed lock (SET if Not eXists)
```

`INCR` is atomic at the Redis level. Two concurrent `INCR` calls never corrupt the counter. Never use `GET` + `SET` to increment — that is a race condition.

### Lists

Ordered, push/pop from either end. Use for: task queues, recent activity feeds, log buffers.

```bash
LPUSH notifications:user:42 '{"type":"order_shipped","orderId":"99"}'
LRANGE notifications:user:42 0 9                 # latest 10 notifications
RPOPLPUSH work:queue work:processing             # reliable queue: atomically move an item,
                                                  # ACK with DEL on successful processing
```

### Hashes

A map stored as a single Redis key. Use for: structured objects where you update individual fields without GET/SET of the whole blob.

```bash
HSET user:42 name "Aadarsh" email "a@example.com" plan "pro"
HGET user:42 name
HINCRBY user:42 login_count 1                    # atomic field increment
HGETALL user:42
```

Use a hash over a JSON string when you frequently update individual fields. Use a JSON string when you always read the entire object at once.

### Sets

Unordered, unique members. Use for: membership tests, unique visitors per day, tag lookups, friend lists.

```bash
SADD product:42:tags "backend" "api" "rest"
SISMEMBER product:42:tags "api"                  # O(1) membership test
SUNIONSTORE result:tags tag_set_1 tag_set_2      # union of two sets
SCARD product:42:tags                            # count members
```

### Sorted Sets (ZSETs)

Ordered by a floating-point score. The single most powerful Redis structure for leaderboards, rate limiters, and scheduled tasks.

```bash
# Leaderboard
ZADD leaderboard 15230 "user:42"
ZADD leaderboard 18900 "user:99"
ZREVRANGE leaderboard 0 9 WITHSCORES             # top 10 with scores
ZRANK leaderboard "user:42"                      # 0-indexed rank from lowest score

# Sliding-window rate limiter: score = request timestamp (unix seconds)
ZADD rate:user:42 1704067200.123 "req:uuid-001"
ZREMRANGEBYSCORE rate:user:42 -inf "(1704067140"  # remove entries older than 60s window
ZCARD rate:user:42                               # count in window; compare to limit
```

### Streams

Append-only log with consumer groups — the modern Redis alternative to a message queue:

```bash
XADD events:orders "*" order_id 99 event "payment_received" amount_paise 5000
XGROUP CREATE events:orders workers $ MKSTREAM  # consumer group, start from latest
XREADGROUP GROUP workers consumer-1 COUNT 10 STREAMS events:orders >
XACK events:orders workers <entry-id>           # acknowledge after processing
```

---

## TTL & Invalidation

### TTL by data volatility

No single TTL fits everything. Align TTL to how fast the data changes:

```
Static reference data (currencies, country list)     → 1–24 hours
User profile / preferences                           → 5–30 minutes
Product catalog prices                               → 1–5 minutes
Search results, aggregated counts                    → 30–60 seconds
Real-time (inventory level, seat availability)       → 5–15 seconds or event-driven invalidation
Session tokens                                       → match session expiry (e.g. 1 hour)
Rate limit windows                                   → exactly the window size
```

### Invalidation patterns

**Time-based (TTL):** Simple, self-healing, tolerates occasional stale reads. Fine for most cases. Fails when staleness is unacceptable (financial balances, inventory, permissions).

**Event-driven invalidation:** On every write, explicitly DELETE the relevant cache keys.

```python
def update_order(order_id: str, user_id: str, data: dict) -> None:
    db.execute("UPDATE orders SET ... WHERE id = %s", [order_id])
    # Invalidate the primary key and any derived/aggregated caches
    redis.delete(f"order:{order_id}")
    redis.delete(f"user:{user_id}:order_summary")
    redis.delete(f"user:{user_id}:order_count")
```

**Tag-based invalidation:** Group cache keys by a tag; invalidate all tagged keys at once. Useful when one entity change invalidates many derived caches:

```python
def set_tagged(key: str, value, tag: str, ttl: int = 300) -> None:
    redis.setex(key, ttl, value)
    redis.sadd(f"cache_tag:{tag}", key)
    redis.expire(f"cache_tag:{tag}", ttl + 60)

def invalidate_tag(tag: str) -> None:
    keys = redis.smembers(f"cache_tag:{tag}")
    if keys:
        redis.delete(*keys)
    redis.delete(f"cache_tag:{tag}")

# Usage: invalidate all caches derived from user 42's data
invalidate_tag("user:42")
```

---

## Stampede & Thundering Herd

A popular cache key expires. Before the first request can re-populate it, 500 concurrent requests all get a miss and all fire the same DB query simultaneously. Your DB goes from 10 req/s to 500 req/s in under a millisecond.

### Pattern 1: Mutex lock on the missing key

```python
import time, json

def get_with_lock(key: str, db_fn, ttl: int = 300):
    value = redis.get(key)
    if value:
        return json.loads(value)

    lock_key = f"lock:{key}"
    acquired = redis.set(lock_key, "1", nx=True, ex=5)  # NX = only if not exists; 5s max hold

    if acquired:
        # This thread won the race — fetch and populate
        result = db_fn()
        redis.setex(key, ttl, json.dumps(result))
        redis.delete(lock_key)
        return result
    else:
        # Another thread is fetching — brief wait then retry
        time.sleep(0.05)
        return get_with_lock(key, db_fn, ttl)
```

### Pattern 2: Probabilistic early expiry (XFetch)

Refresh the cache slightly before expiry, probabilistically — only one thread triggers a refresh at a time, with no explicit lock:

```python
import math, random, json, time

def get_xfetch(key: str, db_fn, ttl: int = 300, beta: float = 1.0):
    raw = redis.get(key)
    remaining = redis.ttl(key)

    if raw:
        data = json.loads(raw)
        delta = data.get("_fetch_ms", 50) / 1000.0   # how long the last fetch took
        # Recompute early with probability that increases as TTL shrinks
        if remaining - delta * beta * math.log(random.random()) < 0:
            result = db_fn()
            payload = {"data": result, "_fetch_ms": delta * 1000}
            redis.setex(key, ttl, json.dumps(payload))
            return result
        return data["data"]

    t0 = time.monotonic()
    result = db_fn()
    fetch_ms = (time.monotonic() - t0) * 1000
    redis.setex(key, ttl, json.dumps({"data": result, "_fetch_ms": fetch_ms}))
    return result
```

### Pattern 3: TTL jitter on bulk cache writes

When a warm-up job populates many keys simultaneously, stagger their TTLs so they don't all expire at the same moment:

```python
import random

def set_with_jitter(key: str, value, base_ttl: int = 300, jitter_fraction: float = 0.1) -> None:
    jitter = int(base_ttl * jitter_fraction * random.random())
    redis.setex(key, base_ttl + jitter, value)
```

---

## Cache Coherence

Cache coherence asks: when does the cached value reflect the true DB state?

### Multi-region coherence

In a multi-region deployment with region-local Redis and a single DB primary:

```
Write → DB primary (us-east-1)
      → publish invalidation event to SNS / Pub/Sub
      → subscriber in eu-west-1 receives event
      → deletes cache key in eu-west-1 Redis
```

The gap between write and remote invalidation is your staleness window (typically 100–500ms). For most reads this is acceptable. For financial balance reads it is not — serve balance reads directly from the DB primary, or use read-your-own-writes via session stickiness.

### In-process caches vs. distributed caches

```
In-process (LRU dict in Python, Caffeine in Java):
  + Zero network latency
  - Each pod has its own cache; a write on pod A doesn't invalidate pod B's copy
  - Pod restart clears the cache
  Use for: static config, read-only reference data, very short TTL (< 5s)

Distributed (Redis):
  + All pods share one cache; a DELETE reaches every pod
  + Survives pod restarts
  - Network round-trip (< 1ms locally, measurable)
  Use for: everything that must be consistent across multiple pods
```

Tiered caching — in-process L1 with a very short TTL (5–30s) in front of Redis L2 — is the standard pattern for static reference data with very high read rates.

---

## CDN & HTTP Caching

HTTP caches — browser, CDN (Cloudflare, Fastly, CloudFront) — are caches you get for free. Most APIs dramatically under-use them.

### Cache-Control header anatomy

```
Cache-Control: max-age=300, stale-while-revalidate=60, stale-if-error=86400

max-age=300                → fresh for 5 minutes; CDN/browser serves from cache
stale-while-revalidate=60  → after 5m, serve stale while fetching fresh in background
                              (user sees no latency spike)
stale-if-error=86400       → if origin is down, serve stale for up to 24h
public                     → may be cached by CDN (default for unauthenticated responses)
private                    → browser cache only; CDN must not cache
no-store                   → never cache (auth-gated data, PII)
must-revalidate            → expired cache must not be served stale (overrides stale-while-revalidate)
immutable                  → response will never change; skip revalidation entirely
```

### ETag and conditional requests

```bash
# First request — server sends ETag
GET /products/42
200 OK
ETag: "d4e5f6a1"
Cache-Control: public, max-age=60

# After expiry, browser/CDN sends conditional request
GET /products/42
If-None-Match: "d4e5f6a1"

# If unchanged: 304 Not Modified  (no body — saves bandwidth and backend CPU)
# If changed:   200 OK with new body and new ETag
```

Implementing ETag in Python:

```python
from flask import request, Response
import hashlib, json

@app.route('/products/<product_id>')
def get_product_endpoint(product_id):
    product = fetch_product(product_id)
    etag = hashlib.md5(json.dumps(product, sort_keys=True).encode()).hexdigest()

    if request.headers.get('If-None-Match') == etag:
        return Response(status=304)

    response = jsonify(product)
    response.headers['ETag'] = etag
    response.headers['Cache-Control'] = 'public, max-age=60, stale-while-revalidate=30'
    return response
```

### Asset fingerprinting vs. API caching

| Resource type | Strategy |
|---------------|----------|
| JS/CSS bundles | Fingerprint filename (`app.abc123.js`); `Cache-Control: max-age=31536000, immutable` |
| API list endpoints | Short TTL (`max-age=30`) + `stale-while-revalidate` |
| API individual resources | ETag + conditional GET |
| User-specific data | `Cache-Control: private, no-store` |
| Auth tokens, session cookies | `Cache-Control: no-store` — never |

---

## Debugging Caching & Performance

The three cache failure modes that surface in production: serving stale data without knowing it, a stampede that DDoSes the database, and a hot key that saturates a single Redis shard.

### Symptom → Cause → Fix

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Users see stale data after an update | Cache invalidation code missing or throwing silently | Log every `redis.delete()` call; write an integration test that mutates then reads and asserts freshness |
| DB CPU spikes to 100% when a popular key expires | Thundering herd — no stampede protection | Add mutex lock (Pattern 1) or XFetch probabilistic refresh (Pattern 2) |
| Redis CPU pegged on one shard; `MONITOR` shows the same key millions of times per second | Hot key — a single product or user is read far more than the others | Local in-process cache in front of Redis; or read replicas with client-side routing; or key fan-out (`product:42:shard:0..N`) |
| Redis memory grows without bound | TTLs missing on some keys, or a new key pattern was added without `EX`/`PX` | `redis-cli --bigkeys` to find top consumers; audit all `SET` and `HSET` calls |
| Cache hit rate below 50% | TTL too short, or the cache is bypassed in some code paths | `INFO stats` for `keyspace_hits`/`keyspace_misses`; trace code paths |
| CDN serving 401 responses to authenticated users | Missing `Cache-Control: private` / `no-store` on auth-gated responses | Always emit `Cache-Control: no-store` on anything requiring authentication |

### Exact Redis diagnostic commands

```bash
# Live stats: hits, misses, ops/sec, memory
redis-cli INFO stats | grep -E 'keyspace_hits|keyspace_misses|instantaneous_ops'
redis-cli INFO memory | grep -E 'used_memory_human|mem_fragmentation_ratio'

# Hit rate: keyspace_hits / (keyspace_hits + keyspace_misses)
# A healthy cache runs at > 90% hit rate for its primary key pattern

# Find the largest keys (top 10 by serialized size)
redis-cli --bigkeys

# Monitor all commands in real time (use sparingly in production — adds latency)
redis-cli MONITOR

# Scan for keys without a TTL (use SCAN, not KEYS, on any non-trivial dataset)
redis-cli --scan --pattern "product:*" | while read key; do
  ttl=$(redis-cli TTL "$key")
  if [ "$ttl" -eq -1 ]; then
    echo "NO TTL: $key"
  fi
done

# Inspect a specific key
redis-cli TTL product:42
redis-cli OBJECT IDLETIME product:42     # seconds since last access
redis-cli DEBUG OBJECT product:42        # encoding, serialized length, last access

# Benchmark a specific access pattern
redis-benchmark -h localhost -p 6379 -n 100000 -c 50 -t get -q --key-prefix "product:42"
```

### Diagnosing stale-cache bugs

```bash
# Compare cache value to DB for the same key
redis-cli GET product:42 | python3 -m json.tool

# Compare to the actual DB row (adjust connection string)
psql -U app -d mydb -c "SELECT id, name, price_paise, updated_at FROM products WHERE id = 42;"

# Find the last time the key was written (OBJECT IDLETIME shows seconds since last READ;
# there is no built-in "last write" — you must store a write timestamp in the value itself
# for debugging, or rely on the TTL as a proxy)
redis-cli OBJECT IDLETIME product:42
```

### Diagnosing a hot-key incident

```bash
# redis-cli MONITOR in a terminal, run for 5 seconds, count unique keys
redis-cli MONITOR | head -5000 | grep -oP '"[^"]*"' | sort | uniq -c | sort -rn | head -20

# With Redis 7.2+ you can use the built-in hot-keys profiling
redis-cli --hotkeys

# If one key dominates (e.g. "product:bestseller"):
# Option 1: add a local in-process TTL cache (e.g. 1 second) in front of Redis
# Option 2: fan out the key: write to product:bestseller:0 through :N, read a random shard
```

> **War story.** A B2C platform I consulted on was serving product prices that were 3–4 hours stale after a flash-sale price change. The invalidation code was correct — `redis.delete(key)` was called on every price update. But the delete was inside a Celery task with `acks_late=False`. When the task crashed after the DB write but before the Redis delete, the message was silently dropped and the key was never invalidated. The fix was two lines: `acks_late=True` on the task and a retry on failure. The deeper lesson: cache invalidation running asynchronously in a task queue is an at-least-once delivery problem, not fire-and-forget. If the queue can drop a message, your cache can serve stale data forever.

---

## Checkpoint

You're ready for the challenges when you can, without looking anything up:

1. Explain why cache-aside invalidates (deletes) the key on write instead of writing the new value.
2. Write the Redis commands to implement a sliding-window rate limiter using a sorted set.
3. Describe the thundering herd problem and show one code-level mitigation (mutex or XFetch).
4. Explain what `Cache-Control: stale-while-revalidate=60` does and name an alternative that avoids stale reads entirely.
5. Choose between an in-process LRU cache and Redis for: (a) exchange rates refreshed hourly, (b) a rate-limit counter shared across 10 pods.
6. Use `redis-cli` to find the 10 largest keys and identify keys that have no TTL set.
7. Describe the write-through vs. write-behind tradeoff in the context of a financial balance update.
8. Given a hot key on `product:bestseller` (100k reads/s), propose two independent mitigations without altering the DB schema or Redis topology.

➡ Next up: challenges — build and profile a cache layer under synthetic load, detect a stampede, and ship a gRPC service to a real kind cluster.
