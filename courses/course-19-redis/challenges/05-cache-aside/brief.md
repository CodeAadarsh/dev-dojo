# Cache-Aside Pattern

Your team's product catalogue API is hammering PostgreSQL on every request. P99 latency on the `/products/{id}` endpoint is 380 ms — almost entirely the DB round trip. The tech lead left a one-line comment in the PR review: *"Redis is right there. Cache-aside. Why aren't we using it?"*

Cache-aside is the most important caching pattern you will implement in backend engineering. This challenge makes you own every step of it against a live Redis instance before you wire it into an application.

## Prerequisites

- Docker running locally.
- Run setup first: `bash courses/course-19-redis/challenges/05-cache-aside/setup.sh`

`setup.sh` ensures the `dojo-redis` container is running and seeds a source-of-truth hash at key `dojo:sot` with three product records. It also scaffolds a work file at `~/.kube-dojo-work/05-cache-aside/commands.sh`.

## Background: The four caching patterns

There are four standard patterns for keeping a cache consistent with a backing store. Understanding which to use — and what each gives up — is the kind of question that separates senior from mid-level engineers.

```
Pattern          Who writes the cache?       When is it written?        Consistency model
─────────────────────────────────────────────────────────────────────────────────────────
Cache-Aside      Application code            On cache miss (lazy)        Eventually consistent
                                                                          TTL-bounded staleness
Write-Through    Application code            On every write              Synchronous, low-lag
Write-Behind     Cache (async to store)      Background flush            Async, data-loss risk
Read-Through     Cache infrastructure        On cache miss (proxy)       Transparent to app
```

**Cache-aside** (also called lazy-loading or look-aside) is by far the most common in practice:

```
Application reads product:1
     │
     ├── GET dojo:cache:product:1  ──→  MISS (key doesn't exist)
     │                                        │
     │                                        ▼
     │                               Read from source of truth
     │                               (DB, another Redis key, API...)
     │                                        │
     │                               SET dojo:cache:product:1 <value> EX 60
     │                                        │
     └──────────────────────────── Return value ◄───────────────────────────

Application reads product:1 (again, within 60s)
     │
     ├── GET dojo:cache:product:1  ──→  HIT  (key exists, TTL > 0)
     │
     └── Return cached value  (no DB round trip)
```

The TTL is not optional. Without expiry, the cache entry lives forever and can serve stale data long after the source has changed. The TTL is your staleness budget — choose it based on how frequently the source changes and how stale the data is tolerable.

## The source of truth

`setup.sh` seeded a Redis hash at `dojo:sot` containing three products:

```
Key: dojo:sot  (type = hash)
  Field          Value
  product:1      Widget|9.99|tools
  product:2      Gadget|14.99|electronics
  product:3      Doohickey|4.99|misc
```

Read a product from the source with `HGET dojo:sot product:1`. This simulates the "expensive" DB read — in a real system this would be a PostgreSQL query; here it's a hash field read in the same Redis instance, but the *pattern* is identical.

## The Mission

Implement cache-aside for all three products. For each product ID (1, 2, 3):

1. **Check the cache**: `EXISTS dojo:cache:product:{id}` — returns 1 (hit) or 0 (miss).
2. **On miss**: read from source (`HGET dojo:sot product:{id}`), then populate the cache with a TTL:
   `SET dojo:cache:product:{id} <value> EX 60`
3. **On hit**: read from cache (`GET dojo:cache:product:{id}`).

After implementing both the miss path and the hit path, `verify.sh` checks:

| Check | Key | Condition |
|-------|-----|-----------|
| Cache populated | `dojo:cache:product:1` | `EXISTS` == 1 |
| TTL set | `dojo:cache:product:1` | `TTL` > 0 |
| Cache populated | `dojo:cache:product:2` | `EXISTS` == 1 |
| TTL set | `dojo:cache:product:2` | `TTL` > 0 |
| Cache populated | `dojo:cache:product:3` | `EXISTS` == 1 |
| TTL set | `dojo:cache:product:3` | `TTL` > 0 |

The verifier does not prescribe the TTL value — any positive integer (seconds) satisfies the check. Use a value that makes sense for data that changes infrequently (60–300 seconds is a reasonable range).

## Key commands reference

```bash
# ── Source of truth ────────────────────────────────────────────────────────────

# Read all fields of the source hash
docker exec dojo-redis redis-cli HGETALL dojo:sot

# Read one product from source (simulates the DB round trip)
docker exec dojo-redis redis-cli HGET dojo:sot product:1

# ── Cache operations ───────────────────────────────────────────────────────────

# Check whether the cache entry exists (1 = hit, 0 = miss)
docker exec dojo-redis redis-cli EXISTS dojo:cache:product:1

# On miss: populate the cache with a 60-second TTL
docker exec dojo-redis redis-cli SET dojo:cache:product:1 "Widget|9.99|tools" EX 60

# On hit: read from cache
docker exec dojo-redis redis-cli GET dojo:cache:product:1

# Check remaining TTL (seconds; -1 = no expiry set; -2 = key gone)
docker exec dojo-redis redis-cli TTL dojo:cache:product:1

# ── After the challenge: inspect the cache state ───────────────────────────────
docker exec dojo-redis redis-cli KEYS "dojo:cache:*"
docker exec dojo-redis redis-cli DEBUG SLEEP 0   # no-op; just checking connection
```

## Why TTL correctness is load-bearing

Setting `EX` is not a nice-to-have. Two concrete failure modes when you omit it:

**Memory exhaustion.** Without expiry, every unique cache key accumulates forever. A catalogue with 500k products loaded lazily over a week fills Redis heap in full. You hit `maxmemory` and, depending on eviction policy, either new writes are rejected or random keys are evicted unpredictably.

**Stale reads after source mutation.** A product's price changes in the DB. The cache entry, never expiring, continues serving the old price until a deploy flushes the cache — or forever. The classic e-commerce P0: customers see a promotional price that expired two weeks ago.

The TTL is your contract with the application about tolerated staleness. Make it explicit.

## Verify

```bash
bash courses/course-19-redis/challenges/05-cache-aside/verify.sh
```
