# Solution: Eviction Policy & AOF Persistence

## The three commands

The entire solution is three `CONFIG SET` calls:

```bash
docker exec dojo-redis redis-cli CONFIG SET maxmemory 100mb
docker exec dojo-redis redis-cli CONFIG SET maxmemory-policy allkeys-lru
docker exec dojo-redis redis-cli CONFIG SET appendonly yes
```

Run the verifier:

```bash
bash courses/course-19-redis/challenges/06-eviction-and-persistence/verify.sh
```

What follows is the deep understanding of *why* these three settings are the right choice, what each does internally, and how production systems manage them at scale.

## maxmemory: why a ceiling is always required for a cache

The default `maxmemory 0` means unlimited — Redis will allocate heap until the OS kills it with `OOM_KILL` (exit code 137) or until the machine swaps to death. Both outcomes are worse than a controlled eviction.

### Choosing a size

On a dedicated Redis instance, the rule of thumb is 75% of available RAM — leaving headroom for:
- The Redis main process overhead (~3–5 MB base).
- AOF buffer (when AOF is enabled, dirty writes queue in memory before fsync).
- Replication backlog (if replicas are attached).
- Copy-on-write fork memory during BGSAVE or BGREWRITEAOF.

On a shared host (as in this dojo), `100mb` is a reasonable exercise value.

```bash
# Human-readable units accepted by CONFIG SET maxmemory:
# 100mb   104857600b   100000kb   (Redis accepts kb/mb/gb with or without 'b')
docker exec dojo-redis redis-cli CONFIG SET maxmemory 100mb

# Verify (always returned in bytes):
docker exec dojo-redis redis-cli CONFIG GET maxmemory
# -> maxmemory, 104857600
```

## maxmemory-policy: allkeys-lru internals

### Why allkeys-lru for a cache

For a **pure cache** (every value is regeneratable from a backing store), `allkeys-lru` is optimal:

- **allkeys**: Redis can evict *any* key, not just those with a TTL. This means even keys without expiry are eligible, which is essential for caches where TTL discipline may be inconsistent.
- **LRU**: Least Recently Used — keeps the hot working set in memory, cold data gets evicted. Access patterns in real systems follow a power-law distribution (a small fraction of keys account for most reads), so LRU naturally keeps the 20% of keys that account for 80% of traffic warm.

### Redis LRU is approximate, not exact

True LRU requires a doubly-linked list of all keys ordered by last-access time — O(N) memory. Redis uses a probabilistic approximation:

1. When eviction is needed, Redis samples `maxmemory-samples` random keys (default: 5).
2. It evicts the one with the oldest LRU clock value.
3. The LRU clock is a 24-bit counter that ticks every 1000ms (so resolution is 1 second, not sub-millisecond).

```
Approximate LRU with maxmemory-samples=5:
  Random sample: key-A (last used 900s ago)
                 key-B (last used 12s ago)
                 key-C (last used 45s ago)
                 key-D (last used 380s ago)
                 key-E (last used 8s ago)
  Evict: key-A  (oldest among sample)
```

Increasing `maxmemory-samples` to 10 produces eviction quality closer to true LRU at a cost of higher CPU per eviction event:

```bash
docker exec dojo-redis redis-cli CONFIG SET maxmemory-samples 10
```

For workloads with a longer-tailed access distribution (many keys accessed once and never again), **allkeys-lfu** (Least Frequently Used) is often a better choice than LRU:

```bash
# LFU variant — available since Redis 4.0
docker exec dojo-redis redis-cli CONFIG SET maxmemory-policy allkeys-lfu
docker exec dojo-redis redis-cli CONFIG SET lfu-decay-time 1        # halve frequency counter every 1 minute
docker exec dojo-redis redis-cli CONFIG SET lfu-log-factor 10       # log-scale counter increment probability
```

## appendonly: AOF persistence mechanics

### What AOF records

Every write command received by Redis is appended to the AOF file *before* the response is sent to the client (with the default `appendfsync everysec` policy — more precisely: written to the OS buffer immediately, fsynced to disk once per second in a background thread).

```
Client:  SET dojo:cache:product:1 "Widget|9.99|tools" EX 60
AOF:     *4\r\n$3\r\nSET\r\n$22\r\ndojo:cache:product:1\r\n$21\r\nWidget|9.99|tools\r\n$2\r\nEX\r\n$2\r\n60\r\n
```

The AOF format is RESP (Redis Serialization Protocol), the same wire format used for client-server communication. On startup, Redis replays the AOF file as a stream of commands, rebuilding in-memory state exactly.

### The three fsync policies

```bash
# Current policy:
docker exec dojo-redis redis-cli CONFIG GET appendfsync
```

| Policy | When fsync happens | Max data loss on crash | Throughput |
|--------|-------------------|------------------------|-----------|
| `always` | After every write | 0 (zero) | ~1,000 writes/s (disk-bound) |
| `everysec` (default) | Background thread, once/second | ~1 second of writes | ~100,000 writes/s |
| `no` | OS decides (~30s) | Up to ~30 seconds | Fastest |

For the rate-limiter use case: `everysec` is the correct choice — you lose at most 1 second of counter increments, which is acceptable.

```bash
# Confirm the fsync policy after enabling AOF:
docker exec dojo-redis redis-cli CONFIG GET appendfsync
# -> appendfsync, everysec  (this is the default when appendonly=yes)
```

### AOF rewrite

Over time the AOF file grows with superseded commands:

```
SET counter 1
SET counter 2
SET counter 3
SET counter 4     <- only this final state matters; the 3 above are dead weight
```

`BGREWRITEAOF` (or the automatic trigger via `auto-aof-rewrite-percentage`) compacts the file to the minimal command set that reproduces current in-memory state:

```bash
# Trigger manual AOF compaction
docker exec dojo-redis redis-cli BGREWRITEAOF

# Check rewrite status
docker exec dojo-redis redis-cli INFO persistence | grep aof_rewrite
```

Automatic rewrite triggers when the AOF file grows by `auto-aof-rewrite-percentage` percent (default: 100%, i.e. doubles in size) AND is larger than `auto-aof-rewrite-min-size` (default: 64mb):

```bash
docker exec dojo-redis redis-cli CONFIG GET auto-aof-rewrite-percentage
docker exec dojo-redis redis-cli CONFIG GET auto-aof-rewrite-min-size
```

### CONFIG SET vs redis.conf vs CONFIG REWRITE

`CONFIG SET` changes the *running process* only. The redis.conf on disk is unchanged. If the container restarts, it re-reads redis.conf and your `CONFIG SET` values are gone.

```bash
# Persist CONFIG SET changes back to redis.conf:
docker exec dojo-redis redis-cli CONFIG REWRITE
```

`CONFIG REWRITE` rewrites the redis.conf file that Redis loaded at startup with the current in-memory config. In the dojo container there is no persistent volume, so this is effectively a no-op across container recreation — but in production with a mounted config volume, `CONFIG REWRITE` is the correct procedure.

The production-grade approach: maintain `redis.conf` in version control with `appendonly yes`, `maxmemory 8gb`, `maxmemory-policy allkeys-lru`. Use `CONFIG SET` only for hot adjustments, and always follow up with `CONFIG REWRITE` to sync.

## Combining RDB and AOF

In production you often want both:

```bash
# RDB: snapshot every 60 seconds if at least 1000 keys changed
docker exec dojo-redis redis-cli CONFIG SET save "60 1000"

# AOF: append-only file for fine-grained recovery
docker exec dojo-redis redis-cli CONFIG SET appendonly yes
```

On restart, if both exist, Redis uses the AOF (more complete). The RDB provides a fast full restore baseline; the AOF brings it current.

Redis 7.0+ introduced **RDB-AOF hybrid format** (`aof-use-rdb-preamble yes`, the default): the AOF starts with a compact RDB snapshot, then appends only the incremental write log. This makes AOF restoration nearly as fast as pure RDB while retaining AOF's granularity.

```bash
docker exec dojo-redis redis-cli CONFIG GET aof-use-rdb-preamble
# -> aof-use-rdb-preamble, yes
```

## Full persistence INFO output

After completing the challenge:

```bash
docker exec dojo-redis redis-cli INFO persistence
```

Key fields to read:

```
rdb_changes_since_last_save:0          <- keys changed since last RDB snapshot
rdb_last_bgsave_status:ok
aof_enabled:1                          <- 1 = AOF active
aof_rewrite_in_progress:0
aof_last_rewrite_time_sec:-1
aof_current_size:0                     <- AOF file size in bytes (0 on fresh container)
aof_base_size:0
aof_pending_rewrite:0
```

`aof_enabled:1` confirms `CONFIG SET appendonly yes` took effect.

## Debugging eviction and persistence

**Keys disappearing unexpectedly:**

```bash
docker exec dojo-redis redis-cli INFO stats | grep evicted_keys
# evicted_keys:42  <- non-zero means Redis is at maxmemory and evicting
```

If `evicted_keys` is rising and you don't expect it, either `maxmemory` is too low or a key population bug is filling the cache faster than TTLs expire it.

**AOF file growing without bound:**

```bash
docker exec dojo-redis redis-cli INFO persistence | grep aof_current_size
# Compare to aof_base_size — if current >> base, rewrite is overdue
docker exec dojo-redis redis-cli BGREWRITEAOF
```

**Checking which keys were evicted most recently:**

Redis does not keep an eviction log, but you can set a keyspace notification to observe eviction events in real time:

```bash
# Enable keyspace notifications for eviction events (K = keyspace, g = generic, e = eviction)
docker exec dojo-redis redis-cli CONFIG SET notify-keyspace-events "Kge"
docker exec -it dojo-redis redis-cli PSUBSCRIBE "__keyevent@0__:evicted"
# Now trigger eviction by filling memory with throwaway keys — evicted key names appear here
```

This is useful in production to understand which specific keys are being evicted under load.
