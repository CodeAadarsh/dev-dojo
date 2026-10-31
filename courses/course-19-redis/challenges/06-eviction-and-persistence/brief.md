# Eviction Policy & AOF Persistence

Your Redis instance is being used for two things simultaneously: session cache (volatile, regeneratable) and rate-limit counters (also volatile, but directionally important). An audit reveals the instance has no memory ceiling and no persistence configured. A runaway key population could take down the entire Redis — and a crash with no persistence means losing all rate-limit state, letting throttled users burst through.

The fix is three `CONFIG SET` calls. But knowing *which* eviction policy to choose, and *what* AOF persistence actually guarantees, is what this challenge is really about.

## Prerequisites

- Docker running locally.
- Run setup first: `bash courses/course-19-redis/challenges/06-eviction-and-persistence/setup.sh`

`setup.sh` ensures the `dojo-redis` container is running and resets the config to defaults so you start from a known state. It scaffolds a work file at `~/.kube-dojo-work/06-eviction-and-persistence/commands.sh`.

## Background: Memory management — eviction policies

When Redis reaches its `maxmemory` ceiling, it must decide what to evict. The policy is one of eight options, and choosing the wrong one causes subtle data loss or unexpected latency spikes.

```
Policy              What Redis evicts when maxmemory is hit
─────────────────────────────────────────────────────────────────────────────────────────
noeviction          Nothing — writes return errors. Appropriate only for durable stores
                    where you cannot afford silent eviction (e.g. a primary DB).

allkeys-lru         Least Recently Used across ALL keys. Best general-purpose cache
                    policy: naturally keeps hot keys in memory, evicts cold ones.

allkeys-lfu         Least Frequently Used across ALL keys. Better than LRU for
                    workloads with a long tail of keys accessed once then never again
                    (e.g. user-event caches). Requires Redis 4.0+.

volatile-lru        LRU, but only among keys that have a TTL set. Keys without TTL are
                    never evicted. Useful when Redis mixes session cache (TTL) with
                    permanent config data (no TTL).

volatile-lfu        LFU among keys with TTL. Same rationale as volatile-lru.

allkeys-random      Evict a random key. Rarely the right choice; useful in tests.

volatile-random     Random eviction among keys with TTL.

volatile-ttl        Evict the key with the shortest remaining TTL first. Reasonable
                    when your TTLs are deliberately graded by importance.
```

For a **pure cache** (every key is regeneratable from a backing store), **`allkeys-lru`** is the correct default. It ensures the most recently accessed data stays warm and cold data is reclaimed automatically — no TTL discipline required from application code.

For a **mixed instance** where some keys must survive (config data, Lua scripts), use `volatile-lru` and make sure the permanent keys have no TTL.

```
Memory usage over time — allkeys-lru vs noeviction

allkeys-lru:
  Memory │▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓ maxmemory
         │          steady state at ceiling: hot keys retained, cold keys recycled
         └──────────────────────────────────────── time

noeviction (misconfigured cache):
  Memory │▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓ OOM → writes fail
         │                                               ↑ OOM_KILLER or ERRORF
         └──────────────────────────────────────────── time
```

## Background: Persistence — RDB vs AOF

Redis offers two on-disk persistence mechanisms. They are not mutually exclusive; production systems often run both.

**RDB (Redis Database Backup) — snapshots**

- Redis forks a child process that writes the entire dataset as a compact binary dump to `dump.rdb`.
- Configurable via `BGSAVE` or `save` directives: `save 900 1` = snapshot if at least 1 key changed in 900 seconds.
- **Recovery model:** point-in-time snapshot. On crash, you lose all writes since the last snapshot (potentially minutes of data).
- **Tradeoffs:** compact, fast to restore (read the whole file into memory on startup), minimal I/O overhead during normal operation. The fork briefly doubles memory usage.

**AOF (Append-Only File) — operation log**

- Every write command (`SET`, `HSET`, `XADD`, etc.) is appended to `appendonly.aof` before (or after) Redis acknowledges the write to the client.
- Three fsync policies:
  - `appendfsync always` — fsync after every write. Maximum durability; ~1 op/s on a spinning disk.
  - `appendfsync everysec` (**default when AOF is on**) — fsync once per second. Lose at most 1 second of writes on crash.
  - `appendfsync no` — let the OS decide (fsync happens ~30s). Fastest; same durability as RDB.
- **Recovery model:** replay all logged commands on startup. Slower to restore than RDB on large datasets.
- **AOF rewrite:** over time the AOF file grows with superseded commands. `BGREWRITEAOF` (or automatic rewrite via `auto-aof-rewrite-percentage`) compacts it to the minimal set of commands that reproduces current state.

For **rate-limit counters** (as in the scenario above), enabling AOF with `everysec` is the right call: you lose at most 1 second of counter increments on a crash, which is far better than losing everything.

## The Mission

Configure the live `dojo-redis` instance using only `CONFIG SET` (no restart, no redis.conf edit):

1. **Set a memory ceiling**: `CONFIG SET maxmemory 100mb` (or any non-zero value — bytes are also accepted, e.g. `104857600`).
2. **Set LRU eviction for all keys**: `CONFIG SET maxmemory-policy allkeys-lru`.
3. **Enable AOF persistence**: `CONFIG SET appendonly yes`.

`verify.sh` checks three conditions:

| Check | CONFIG GET key | Required value |
|-------|----------------|---------------|
| Eviction policy set | `maxmemory-policy` | `allkeys-lru` |
| Memory ceiling set | `maxmemory` | `> 0` (any non-zero byte count) |
| AOF enabled | `appendonly` | `yes` |

## Key commands reference

```bash
# ── Read current config ────────────────────────────────────────────────────────

# Check current eviction policy (default: noeviction)
docker exec dojo-redis redis-cli CONFIG GET maxmemory-policy

# Check current maxmemory (0 = unlimited)
docker exec dojo-redis redis-cli CONFIG GET maxmemory

# Check AOF status
docker exec dojo-redis redis-cli CONFIG GET appendonly

# ── Apply the three settings ───────────────────────────────────────────────────

# 1. Set memory limit (accepts human-readable units: kb, mb, gb)
docker exec dojo-redis redis-cli CONFIG SET maxmemory 100mb

# 2. Evict least recently used keys across all keys when maxmemory is reached
docker exec dojo-redis redis-cli CONFIG SET maxmemory-policy allkeys-lru

# 3. Enable AOF persistence (writes append to appendonly.aof)
docker exec dojo-redis redis-cli CONFIG SET appendonly yes

# ── Verify manually ────────────────────────────────────────────────────────────

# See all memory-related config in one call
docker exec dojo-redis redis-cli CONFIG GET maxmemory*

# Check that AOF rewrite info looks healthy
docker exec dojo-redis redis-cli INFO persistence
```

## Important caveats

**`CONFIG SET` is ephemeral across container restarts.** These settings only apply to the *running process*. If the container is removed and re-created (e.g. `docker restart --no-start dojo-redis`), it starts with defaults. For production you commit settings to `redis.conf` and use `CONFIG REWRITE` to sync the live config back to disk.

**AOF on a container without a mounted volume.** The AOF file is written inside the container filesystem. If the container is removed, the file is gone — defeating the purpose. In production, mount a persistent volume: `-v /data/redis:/data`. This challenge focuses on understanding the mechanics, not production-grade volume setup.

**`allkeys-lru` is approximate, not exact LRU.** Redis does not maintain a true LRU doubly-linked list over all keys (that would cost O(n) memory). Instead, it uses a probabilistic algorithm: sample `maxmemory-samples` random keys (default 5) and evict the least recently used of that sample. Increase `maxmemory-samples` to 10 for a closer approximation of true LRU at the cost of slightly higher CPU on eviction.

## Verify

```bash
bash courses/course-19-redis/challenges/06-eviction-and-persistence/verify.sh
```
