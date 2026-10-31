# Memory & Eviction

> **Module 04 · Course 19** — Redis lives in memory. When memory fills up, one of three things happens: the server rejects writes, it silently deletes keys you thought were safe, or it deletes exactly the keys you wanted deleted. Which outcome you get depends entirely on how you've configured `maxmemory` and the eviction policy — and most production incidents happen because nobody thought carefully about this configuration.

---

## `maxmemory`: the hard ceiling

`maxmemory` sets the maximum amount of memory Redis is allowed to use. When used memory reaches this limit, Redis applies the eviction policy to every subsequent write command.

```bash
# Set a 2 GB limit (dynamically, no restart required):
redis-cli config set maxmemory 2gb

# Check current state:
redis-cli info memory | grep -E 'used_memory_human|maxmemory_human|maxmemory_policy'
# used_memory_human:1.85G
# maxmemory_human:2.00G
# maxmemory_policy:allkeys-lru
```

### What counts toward `maxmemory`

`maxmemory` is compared against `used_memory` — the bytes allocated by the Redis allocator (jemalloc). It does NOT count:

- The OS-level memory overhead of the redis-server process itself (code, stack, libraries).
- Replication buffer (`client-output-buffer-limit replica`).
- Replica backlog (`repl-backlog-size`).
- AOF rewrite buffer.

This means the actual RSS of the process can be 20–30% higher than `maxmemory` allows. Size your container/host accordingly — `maxmemory = 80%` of available RAM is a common safe starting point.

### `maxmemory 0` — no limit

The default is `0` (no limit). Redis will allocate as much memory as the OS allows. On a dedicated Redis host this is often fine. In a container, it is a recipe for the container being OOM-killed by the kernel, which is a hard crash with no warning.

**Always set `maxmemory` explicitly when running Redis in a container or on a shared host.**

---

## Eviction Policies

When a write command arrives and `used_memory >= maxmemory`, Redis applies the eviction policy before executing the command. The policy decides which key (if any) to delete to make room.

### The eight policies

```
noeviction (default):
  No keys are evicted. Return an OOM error to the client for write commands.
  READ commands still work.
  Use when: Redis is a primary data store, data loss is unacceptable.

allkeys-lru:
  Evict the key that was least recently used, across ALL keys.
  Use when: Redis is a cache and all keys have roughly equal importance.

volatile-lru:
  Evict the key that was least recently used, but ONLY among keys with a TTL.
  Use when: some keys are permanent (config, reference data) and must not be evicted;
            cache keys have TTLs and are fair game.

allkeys-lfu:
  Evict the key accessed least frequently, across ALL keys. (LFU = Least Frequently Used)
  Better than LRU for workloads where popular keys are accessed in bursts:
  a key not used for 2 seconds is not "cold" if it gets 1000 hits/min normally.
  Use when: you have a Zipf-distributed access pattern (most traffic to a small hot set).

volatile-lfu:
  Like allkeys-lfu but only among TTL keys.

allkeys-random:
  Evict a random key, across all keys.
  Use when: access pattern is uniform; you don't want CPU overhead of LRU/LFU tracking.

volatile-random:
  Evict a random TTL key.

volatile-ttl:
  Evict the TTL key with the shortest remaining time-to-live.
  Use when: fresher data is more valuable; you want near-expired data gone first.
```

### LRU vs LFU — when it matters

**LRU** (Least Recently Used) evicts based on *recency of the last access*. A key accessed 100 times yesterday but not today is treated the same as a key never accessed.

**LFU** (Least Frequently Used) evicts based on *access frequency* over time, using an exponential decay so old accesses fade. A key accessed 100 times per minute is hot even if not accessed in the last 5 seconds.

```
Scenario: web session cache, Zipf distribution
  key "session:homepage_config"  — 1,000 accesses/sec (hot)
  key "session:user:99999"       — last accessed 30 seconds ago (cold today)

  LRU: might evict session:homepage_config if it wasn't the most recent access
       (unlikely in practice because it's accessed so often, but theoretically possible)
  LFU: will never evict session:homepage_config because its frequency counter is high
```

For most caching workloads with Zipf access patterns, `allkeys-lfu` produces better cache hit rates than `allkeys-lru`. But LFU has slightly higher memory overhead per key (frequency counter).

### Approximated LRU and LFU

Redis does not maintain a global sorted-by-access-time list (that would be O(log N) on every access). Instead it uses **sampling**: when eviction is needed, Redis samples `maxmemory-samples` keys (default: 5) and evicts the best candidate from the sample.

```bash
redis-cli config get maxmemory-samples   # default: 5
redis-cli config set maxmemory-samples 10  # more accurate, more CPU
```

With 5 samples, the approximation is good enough for most workloads. With 10 samples it approaches ideal LRU accuracy at roughly 2× the CPU cost. The Redis paper on this topic shows the accuracy curve flattens quickly — 10 samples is close to perfect.

---

## Key Expiration: Lazy + Active

Setting a TTL does not guarantee the key is deleted at exactly the expiry time. Redis uses a two-pronged approach:

### 1. Lazy expiration

When a client accesses a key (GET, HGET, anything), Redis checks whether the key has expired. If it has, Redis deletes it on the spot and returns nil/not-found to the client. No background work needed for this case.

```bash
SET greeting "hello" EX 10      # expires in 10 seconds
# ... wait 15 seconds ...
GET greeting                    # triggers lazy check → key deleted → returns (nil)
```

**Problem with lazy-only**: if a key expires but is never accessed again, it sits in memory forever. An application that writes many TTL keys but never reads them back (fire-and-forget cache warm) would leak memory indefinitely.

### 2. Active expiration sweep

`serverCron` runs an active sweep every `1000/hz` milliseconds (default: 100 ms with `hz=10`). Each sweep:

1. For each database (usually just db 0):
   a. Sample `ACTIVE_EXPIRE_CYCLE_LOOKUPS_PER_LOOP` keys from the expires dictionary (default: 20).
   b. Delete all expired keys in the sample.
   c. If > 25% of the sampled keys were expired, run another cycle immediately (the dataset is "hot with expired keys" — keep sweeping).
   d. Stop when the expiration rate drops below 25% or the time budget is exceeded.

The time budget per sweep is either 25% of a serverCron cycle (in FAST mode) or up to 1 ms (in SLOW mode, triggered when the server is idle).

```
┌──────────────────────────────────────────────────────────────────┐
│  Expiry sweep behavior:                                          │
│                                                                  │
│  100 ms (hz=10)      100 ms        100 ms        100 ms         │
│     │                   │             │             │            │
│     ▼                   ▼             ▼             ▼            │
│  [sweep: sample 20]  [sweep]       [sweep]       [sweep]        │
│   - 3 expired → del   (2 expired)   (0 expired)   (6 expired)  │
│   - 3/20 = 15% < 25%  stop          stop          30% > 25%    │
│     stop now                                       → extra loop │
└──────────────────────────────────────────────────────────────────┘
```

**Implication**: keys do not expire at exactly their TTL time. In practice they expire within a few hundred milliseconds of their TTL under normal sweep rates. Under extreme load (millions of keys expiring at once), the sweep falls behind and keys may persist for seconds past their TTL. The `hz` setting trades CPU cost for expiration precision.

### TTL commands

```bash
SET session "abc" EX 3600          # expire in 3600 seconds
SET session "abc" PX 3600000       # expire in 3600000 milliseconds
SET session "abc" EXAT 1800000000  # expire at unix timestamp (seconds)
SET session "abc" PXAT 1800000000000  # expire at unix timestamp (milliseconds)

TTL session           # remaining seconds (-1 = no expiry, -2 = key doesn't exist)
PTTL session          # remaining milliseconds
PERSIST session       # remove the TTL (make key permanent)
EXPIRETIME session    # unix timestamp of expiry (Redis 7+)
```

---

## OOM Behavior: What Happens When Eviction Cannot Free Enough Memory

When memory is full and no keys can be evicted (either `noeviction` policy, or all evictable keys are too small to make room for the incoming write), Redis returns:

```
(error) OOM command not allowed when used memory > 'maxmemory'.
```

Clients see this as an exception:
- redis-py: `redis.exceptions.ResponseError: OOM ...`
- Jedis: `redis.clients.jedis.exceptions.JedisDataException: OOM ...`
- go-redis: standard error string

**READ commands still succeed under OOM.** Only write commands that increase memory are blocked. `GET`, `HGET`, `LRANGE`, `ZRANGE` all work. The blocked commands are those tagged with the `m` flag (may increase memory) — `SET`, `LPUSH`, `HSET`, `SADD`, `ZADD`, etc.

### OOM under eviction policies

With `allkeys-lru` (or any eviction policy other than `noeviction`), Redis will attempt to evict before returning OOM. If it can free enough memory, the write proceeds. If the dataset has no evictable keys (all keys are referenced by a Lua script, a blocked client, or a replica sync in progress), OOM is returned even under eviction policies.

---

## Memory Fragmentation

Even if `used_memory` is below `maxmemory`, the RSS may be much higher. The gap is **fragmentation**: the allocator has committed physical pages to the process but some pages are partially unused (holes in the allocator's free lists).

```bash
redis-cli info memory | grep -E 'used_memory_human|used_memory_rss_human|mem_fragmentation_ratio|mem_fragmentation_bytes'
# used_memory_human:1.50G        <- bytes in use by Redis objects
# used_memory_rss_human:2.10G    <- bytes committed by OS to this process
# mem_fragmentation_ratio:1.40   <- 2.1 / 1.5 = 40% fragmentation
# mem_fragmentation_bytes:644245504
```

**Fragmentation ratio interpretation:**

| Ratio | Meaning |
|-------|---------|
| < 1.0 | Swapping (memory is being paged to disk — very bad) |
| 1.0–1.5 | Healthy (normal allocator overhead) |
| 1.5–2.0 | Elevated fragmentation — monitor closely |
| > 2.0 | High fragmentation — active defrag recommended |

### Causes of fragmentation

1. **Mass key deletion**: when many keys are deleted at once (e.g., expiry sweep clears millions of session keys at midnight), the allocator's free lists fill up with many small holes that don't add up to usable contiguous blocks.

2. **Encoding promotions**: growing a hash from listpack to hashtable frees a listpack (small, contiguous) and allocates many small `dictEntry` structs. The old allocation may not exactly match any future allocation size.

3. **Append-heavy workloads**: `APPEND` on strings causes SDS reallocation with growth factor, leaving old SDS blocks freed.

4. **jemalloc vs libc**: jemalloc (Redis default since 2.4) is much better at fragmentation management than libc malloc. If you're running a distro-compiled Redis with libc malloc, fragmentation will be higher.

### Active defragmentation

Redis 4+ includes an active defragmenter (`activedefrag`):

```bash
redis-cli config set activedefrag yes

# Tuning knobs:
redis-cli config set active-defrag-ignore-bytes 100mb   # start only when > 100 MB fragmented
redis-cli config set active-defrag-enabled yes
redis-cli config set active-defrag-threshold-lower 10   # start at 10% frag ratio above 1.0
redis-cli config set active-defrag-threshold-upper 100  # run at max effort above 100% waste
redis-cli config set active-defrag-cycle-min 1          # min % of CPU for defrag
redis-cli config set active-defrag-cycle-max 25         # max % of CPU for defrag
```

Active defrag works by:
1. Scanning through all allocations.
2. When it finds a fragmented page, allocating a fresh copy of the object.
3. Updating the pointer in the Redis data structure to the new location.
4. Freeing the old allocation (returning the fragmented page to the allocator).

It runs on the main thread in small increments, limited by `active-defrag-cycle-max`. It should not cause noticeable latency unless you set the max very high.

```bash
# Monitor defrag progress:
redis-cli info stats | grep -E 'active_defrag'
# active_defrag_running:1
# active_defrag_hits:124532
# active_defrag_misses:3421
# active_defrag_key_hits:89234
# active_defrag_key_misses:1234
```

---

## MEMORY USAGE: Measuring What Keys Actually Cost

`MEMORY USAGE key [SAMPLES N]` walks the object graph and estimates the total memory usage of a key including all referenced objects:

```bash
MEMORY USAGE user:session:1                    # quick estimate
MEMORY USAGE user:session:1 SAMPLES 0         # deep walk, accurate (slow for big objects)
MEMORY USAGE user:session:1 SAMPLES 200       # sample 200 entries for estimation
```

For a hash:
- `SAMPLES 0`: walks ALL fields and values. Accurate but O(N).
- `SAMPLES N`: walks N randomly sampled fields, extrapolates. Good estimate for large hashes.

```bash
# Find all keys over 100 KB using SCAN + MEMORY USAGE:
redis-cli --scan | while read key; do
  sz=$(redis-cli memory usage "$key" samples 50 2>/dev/null || echo 0)
  [ "$sz" -gt 102400 ] && echo "$sz $key"
done | sort -rn | head -20
```

Other MEMORY subcommands:

```bash
MEMORY DOCTOR          # overall health diagnosis text
MEMORY MALLOC-STATS    # jemalloc internal allocator statistics
MEMORY PURGE           # ask jemalloc to release free pages to OS (may help RSS)
MEMORY STATS           # full breakdown: dataset, overhead, peak, allocator
```

---

## Eviction in Practice: Worked Examples

### Example 1: Cache with allkeys-lru

An API caches product data. All keys follow `product:{id}` with no TTL.

```bash
redis-cli config set maxmemory 512mb
redis-cli config set maxmemory-policy allkeys-lru

# Fill cache:
for i in $(seq 1 100000); do
  redis-cli set "product:$i" "$(head -c 4096 /dev/urandom | base64)" > /dev/null
done

# Once memory hits 512 MB, LRU eviction begins automatically.
# The least recently accessed product data is evicted first.
# Popular products (frequent reads) stay; stale ones are evicted.
```

Monitor eviction rate:

```bash
redis-cli info stats | grep evicted_keys
# evicted_keys:4231   <- cumulative evictions since start

redis-cli info stats | grep keyspace_hits
redis-cli info stats | grep keyspace_misses
# Cache hit ratio = hits / (hits + misses)
```

### Example 2: Session store with volatile-lru

Authentication sessions have TTLs. Config data (JWT public keys, feature flags) should never be evicted.

```bash
# Session keys: always set with TTL
SET session:abc123 "{...}" EX 3600

# Config keys: no TTL (permanent — volatile-lru will NOT evict these)
SET config:jwt_pubkey "..."

redis-cli config set maxmemory-policy volatile-lru
```

When memory fills: only TTL keys are eviction candidates. The least recently accessed sessions go first. Config keys are untouched regardless of memory pressure.

### Example 3: Rate limiting keys with volatile-ttl

Rate limit windows use short TTLs. When memory is tight, evict the keys closest to expiring — they're about to go away anyway.

```bash
# Rate limit keys with sliding window TTLs
SET ratelimit:user:1001:window:1714123456 "42" EX 60

redis-cli config set maxmemory-policy volatile-ttl
# Keys with TTL remaining = 1 second are evicted before TTL remaining = 59 seconds
```

---

## Debugging: OOM Errors

### Symptom

Application logs show: `redis.exceptions.ResponseError: OOM command not allowed when used memory > 'maxmemory'`

Or from redis-cli directly:

```bash
redis-cli set test "x"
# (error) OOM command not allowed when used memory > 'maxmemory'.
```

### Diagnosis

```bash
redis-cli info memory
# used_memory_human:2.00G
# maxmemory_human:2.00G      <- at the limit

redis-cli info stats | grep evicted_keys
# evicted_keys:0             <- if 0 and policy is not noeviction, something is wrong

redis-cli config get maxmemory-policy
# noeviction                 <- this explains the OOM: eviction is disabled
```

### Diagnosis checklist

1. **Is eviction enabled?** `maxmemory-policy` is `noeviction` → either accept OOM or change policy.
2. **Are there any evictable keys?** With `volatile-lru`, if no keys have TTLs, nothing can be evicted.
3. **Is memory genuinely full or is it fragmentation?** Check `mem_fragmentation_ratio`. If it's 2.0+, the real data may fit but fragmentation is eating physical memory.
4. **Is a replica backlog consuming unaccounted memory?** The replication backlog (`repl-backlog-size`) is not counted toward `maxmemory` but does consume process memory.

```bash
redis-cli info replication | grep -E 'repl_backlog_size|repl_backlog_histlen'
# repl_backlog_size:1073741824    <- 1 GB backlog, not counted in maxmemory!
```

If the backlog plus `maxmemory` exceeds host RAM, the host OOMs.

### Fixing OOM

```bash
# Option 1: Increase maxmemory (if host has more RAM)
redis-cli config set maxmemory 3gb

# Option 2: Enable eviction
redis-cli config set maxmemory-policy allkeys-lru

# Option 3: Add TTLs to keys that should be cache-like
# (application-side change)

# Option 4: Release fragmentation (may help temporarily)
redis-cli memory purge

# Option 5: Delete big unused keys immediately
redis-cli --bigkeys   # find candidates
redis-cli unlink "big:key:name"
```

---

## Debugging: Surprise Evictions

### Symptom

Keys disappear from Redis without explicit `DEL` commands. Application returns cache misses on keys that were just written. `keyspace_misses` is climbing unexpectedly.

### Diagnosis

```bash
redis-cli info stats | grep evicted_keys
# evicted_keys:12453230   <- high and growing

redis-cli info memory | grep -E 'used_memory_human|maxmemory_human'
# used_memory_human:512.00M
# maxmemory_human:512.00M   <- at the limit, eviction is active

redis-cli config get maxmemory-policy
# allkeys-lru               <- evicting LRU keys

redis-cli info stats | grep keyspace
# keyspace_hits:8923421
# keyspace_misses:2341238   <- hit ratio = 8.9M/(8.9M+2.3M) = 79%
```

A hit ratio below 80% for a cache is usually a signal that the cache is too small for the working set — eviction is removing keys that are still being accessed.

**Identify which keys are being evicted:**

Enable keyspace notifications (note: this adds CPU overhead):

```bash
redis-cli config set notify-keyspace-events "Kg"   # K=keyspace, g=generic (includes eviction)
# Subscribe to eviction notifications:
redis-cli psubscribe "__keyevent@0__:evicted"
# Shows every key eviction in real time
```

**Better: measure per-key eviction with a monitor sample:**

```bash
redis-cli monitor | grep -E 'evict|expired' | head -100
# Shows actual evictions and expirations as they happen
```

### Mitigations

| Cause | Fix |
|-------|-----|
| Cache too small for hot working set | Increase `maxmemory`; add more instances; use consistent hashing to shard |
| Evicting keys that should be permanent | Switch from `allkeys-lru` to `volatile-lru`; add no-TTL to permanent keys |
| Wrong eviction policy for access pattern | Try `allkeys-lfu` for Zipf-distributed access |
| Application not handling cache misses | Implement read-through caching; add circuit breaker for cache miss storm |

---

## Debugging: Fragmentation

### Symptom

`maxmemory` is 2 GB. `used_memory` is 1.8 GB. But the Redis process RSS is 3.2 GB and the host is OOM-killing the process.

### Diagnosis

```bash
redis-cli info memory
# used_memory:1932735488       <- 1.8 GB in use by Redis objects
# used_memory_rss:3435008000   <- 3.2 GB committed by OS
# mem_fragmentation_ratio:1.77 <- 77% overhead
# mem_fragmentation_bytes:1502272512
```

### Cause identification

```bash
redis-cli memory malloc-stats
# jemalloc internal stats — look for "retained" pages and large fragmented arenas

# Check if recent mass deletion happened:
redis-cli info stats | grep expired_keys
# expired_keys:8921345   <- 8.9M expirations recently? That's a mass deletion pattern
```

### Mitigations

```bash
# 1. Enable active defrag
redis-cli config set activedefrag yes
redis-cli config set active-defrag-ignore-bytes 500mb
redis-cli config set active-defrag-threshold-lower 10

# 2. Ask jemalloc to release free pages to the OS:
redis-cli memory purge   # non-blocking, may take a moment to reflect in RSS

# 3. Monitor defrag progress:
redis-cli info stats | grep active_defrag

# 4. If fragmentation is very high and active defrag is not making progress:
#    Schedule a restart during low traffic to fully compact memory
#    (replica promotion + failover if using Sentinel/Cluster)
```

---

## The Full Memory Hierarchy

Understanding all the layers of memory in a Redis deployment:

```
┌─────────────────────────────────────────────────────────────────────┐
│  Host / Container                                                   │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │  redis-server process RSS                                     │  │
│  │  ┌───────────────────────────────────────────────────────┐   │  │
│  │  │  used_memory (maxmemory limit applies here)           │   │  │
│  │  │  ┌─────────────────────────────────────────────┐     │   │  │
│  │  │  │  dataset (keys + values)                    │     │   │  │
│  │  │  ├─────────────────────────────────────────────┤     │   │  │
│  │  │  │  overhead: dict tables, expire dict, etc.   │     │   │  │
│  │  │  └─────────────────────────────────────────────┘     │   │  │
│  │  ├───────────────────────────────────────────────────────┤   │  │
│  │  │  replication backlog (NOT in maxmemory)               │   │  │
│  │  │  AOF rewrite buffer (NOT in maxmemory)                │   │  │
│  │  │  allocator fragmentation overhead                     │   │  │
│  │  └───────────────────────────────────────────────────────┘   │  │
│  │  code segment, stack, linked libraries                        │  │
│  └───────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
```

The practical rule: `maxmemory` = 60–75% of available host RAM. Leave headroom for:
- Fragmentation (~20% overhead in the worst case).
- Replication backlog.
- AOF rewrite buffer (can peak at the size of the dataset during rewrite).
- OS page cache and other processes.

For containers: set the container memory limit at least 50% above `maxmemory`. A container with `limit=2GB` and `maxmemory=2GB` will be OOM-killed by the kernel because the process RSS exceeds 2 GB even when `used_memory` is exactly 2 GB.

---

## Checkpoint

1. What is the default `maxmemory-policy`? What happens to write commands when memory is full with this policy? What about read commands?
2. Explain the difference between `used_memory` and `used_memory_rss`. What is `mem_fragmentation_ratio` and at what value does it indicate a problem?
3. A session store uses `volatile-lru`. A developer stores feature flags as permanent keys (no TTL). At 99% memory usage, which keys are candidates for eviction? Why?
4. Why does active expiration not guarantee a key is deleted exactly at its TTL time? Under what conditions could a key survive for several seconds past its TTL?
5. You see `evicted_keys` incrementing at 1000/sec and cache hit ratio is 65%. What does this tell you about the relationship between `maxmemory` and the application's working set size?
6. A Redis container with `memory_limit=4GB` and `maxmemory=4GB` keeps getting OOM-killed by the Linux kernel. Explain why and state the fix.
7. What does `MEMORY PURGE` do? When does it help with RSS and when does it not?
8. Compare `allkeys-lru` vs `allkeys-lfu` for a leaderboard service where the top 10 players are accessed 99% of the time and the bottom 10,000 are rarely accessed. Which policy would produce a better cache hit rate?
9. Explain how the lazy expiration + active sweep design avoids holding the event loop for long periods when millions of keys expire simultaneously.
10. A Redis instance has `maxmemory 0` deployed in a Kubernetes pod with a 4 GB memory limit. A traffic spike causes memory to grow to 3.8 GB. Describe the failure chain and how you would prevent it.

→ Next up: Redis challenges — put these concepts to work against a live Redis instance.
