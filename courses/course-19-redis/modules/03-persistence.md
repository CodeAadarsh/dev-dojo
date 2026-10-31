# Persistence: RDB & AOF

> **Module 03 · Course 19** — Redis is an in-memory database. Without persistence, a restart is a blank slate. With it, the question is: how much data are you willing to lose in the worst case, and how much CPU and I/O cost are you willing to pay to reduce that window? This module makes the tradeoff concrete.

Persistence in Redis is not a simple on/off switch. It is a dial between **performance** and **durability**, and understanding where you set it — and why — is an operational responsibility.

---

## The Fundamental Tradeoff

```
     No persistence                     Full durability
          │                                    │
          ▼                                    ▼
     0 ms overhead                       1–10 ms per write
     All data lost on restart            At most ~1 commit lost
     Memory-only cache                   Durable store
          │                                    │
          └──────────────┬─────────────────────┘
                         │
              RDB (snapshots): seconds to minutes of data loss
                         │
              AOF everysec: ~1 second of data loss
                         │
              AOF always:  at most one write transaction lost
```

A misconfigured or misunderstood persistence mode has caused more Redis data-loss incidents than any other single cause. The defaults are intentionally conservative for safety, but production systems often need to deviate deliberately.

---

## RDB: Snapshot Persistence

RDB (Redis Database) creates a point-in-time binary snapshot of the entire dataset. It is the default persistence mechanism.

### What a snapshot contains

An RDB file is a compact binary encoding of the full keyspace at the moment of the fork. It includes:
- All key-value pairs.
- Expiry times (so TTLs survive restarts).
- LRU/LFU access information (for eviction policies that need it).
- A CRC64 checksum at the end.

RDB files are designed to be compact and fast to load — a 10 GB dataset loads in about 10–30 seconds. They are also suitable for backup and disaster recovery: copy the file off-host at any time.

### Triggering a snapshot

**Manually:**

```bash
redis-cli BGSAVE              # background: fork a child, returns immediately
redis-cli SAVE                # foreground: blocks ALL clients until done — NEVER in production
redis-cli LASTSAVE            # unix timestamp of last successful RDB save
```

**Automatically via `save` directives:**

```
# in redis.conf (or set via CONFIG SET):
save 3600 1      # save after 3600 seconds if ≥1 key changed
save 300 100     # save after 300 seconds if ≥100 keys changed
save 60 10000    # save after 60 seconds if ≥10000 keys changed
```

Multiple `save` lines create a logical OR — any condition met triggers a background save. To disable automatic saves:

```bash
redis-cli config set save ""
```

### How BGSAVE works: fork and copy-on-write

```
Timeline (wall clock)
  0 ms   ┌─── main thread: redis-cli BGSAVE ──────────────────────────────►
         │    fork() call
         │    ▼
  1 ms   │   [OS creates child process]
         │    child inherits all page-table entries (COW: copy-on-write)
         │    child starts iterating all keys and writing RDB stream to temp file
         │
         │    main thread continues serving clients:
         │    - SET foo bar2  → OS creates a new copy of the memory page
         │                      containing "bar" for the main thread
         │                      child still sees the old "bar" in its page-table
         │
  N sec  │   child: finishes writing all keys → renames temp file to dump.rdb → exits
         │   main thread: receives SIGCHLD, logs "Background saving terminated"
         └──────────────────────────────────────────────────────────────────►
```

**Copy-on-write (COW)** is the kernel mechanism that makes this safe and (mostly) cheap:

- Before the fork, main thread and child share all physical memory pages.
- When the main thread writes to any page (because clients keep writing), the OS duplicates that page for the main thread. The child sees the original.
- Memory overhead during a snapshot is proportional to the write rate × snapshot duration × page size (typically 4 KB).

**Why this causes latency:**

`fork()` itself is not free. On Linux, `fork()` must copy the page-table, which is proportional to the process RSS:

```
RSS       Typical fork() time (bare metal, modern Linux)
─────     ────────────────────────────────────────────
1 GB      5–20 ms
10 GB     50–200 ms
50 GB     250–1000 ms+
```

During those milliseconds, the main thread is inside the `fork()` syscall and **cannot serve any commands**. All connected clients see a latency spike.

You can observe this:

```bash
redis-cli info stats | grep fork_avg_cpumsec  # average fork CPU time in ms
redis-cli debug jmap                           # (DEBUG builds) memory map
redis-cli latency history rdb-fork-diff-coe    # fork latency history
```

### RDB file configuration

```bash
# Location and filename
redis-cli config set dir /var/lib/redis
redis-cli config set dbfilename dump.rdb

# Compression (snappy/LZ for the RDB file itself)
redis-cli config set rdbcompression yes    # default: yes, saves ~30% size
redis-cli config set rdbchecksum yes       # default: yes, CRC64 validation on load
```

### RDB durability: data loss window

With `save 60 10000`, in the worst case (Redis dies 59 seconds into a period with 9999 writes, just before the next scheduled save), you lose up to 59 seconds of writes. For a cache-aside pattern where the DB is the source of truth, this is often acceptable. For a primary data store, it is not.

---

## AOF: Append-Only File

AOF logs every write command to a file as it executes, in RESP format. On restart, Redis replays the AOF to reconstruct the dataset.

### How it works

```
Client: SET counter 1
        INCR counter
        INCR counter
        SET user:1 "alice"

AOF file:
  *3\r\n$3\r\nSET\r\n$7\r\ncounter\r\n$1\r\n1\r\n
  *2\r\n$4\r\nINCR\r\n$7\r\ncounter\r\n
  *2\r\n$4\r\nINCR\r\n$7\r\ncounter\r\n
  *3\r\n$3\r\nSET\r\n$6\r\nuser:1\r\n$5\r\nalice\r\n
```

On restart, Redis reads the AOF and re-executes each command. After replay, the state is identical to what it was at crash time (minus the commands in the `fsync` buffer — see below).

### Enabling AOF

```bash
redis-cli config set appendonly yes
redis-cli config set appendfilename "appendonly.aof"
```

### The three `appendfsync` modes

This is the most consequential AOF configuration decision:

```
appendfsync always
  ├── Every write command: write() to kernel buffer + fsync() to disk
  ├── Durability: at most ONE command lost (the one in progress during crash)
  └── Performance: 1–10 ms per write (limited by disk fsync latency)
      Throughput typically: 100–3000 writes/sec on SSD

appendfsync everysec  (DEFAULT)
  ├── Every write command: write() to kernel buffer
  ├── Every 1 second: background thread calls fsync()
  ├── Durability: at most ~1 second of data lost
  └── Performance: ~microsecond overhead per write; fsync background
      Throughput: same as no persistence for most workloads

appendfsync no
  ├── Every write command: write() to kernel buffer
  ├── fsync: left entirely to the OS (typically every 30 seconds)
  ├── Durability: up to 30+ seconds of data lost
  └── Performance: fastest (no forced fsync overhead)
      Used when AOF is just for replay convenience, not crash safety
```

**`always` in practice**: on a magnetic disk, `fsync` takes 5–10 ms, limiting you to ~100–200 writes/sec. On an NVMe SSD, `fsync` takes ~100 µs, giving 5K–10K write/sec. For `always` mode to be viable, you need fast local storage and your workload must tolerate it.

**`everysec` is the safe default**: you lose at most ~1 second of writes. For most applications this is a reasonable tradeoff. The BIO thread handles `fsync()` asynchronously, so main-thread write latency is unaffected unless the disk falls behind.

### AOF growth and rewrite

A pure AOF log grows without bound. After a million `INCR counter` commands, the AOF has a million lines but the counter has one final value. **AOF rewrite** (also called compaction) rewrites the AOF by scanning the current in-memory dataset and writing the minimal set of commands to reconstruct it:

```bash
redis-cli BGREWRITEAOF      # trigger background rewrite
```

The rewrite uses `fork()` and the same COW mechanism as BGSAVE:

1. Redis forks a child.
2. The child writes a new AOF file reflecting the current in-memory state.
3. While the child is writing, the main thread buffers new write commands in a rewrite buffer.
4. When the child finishes, the main thread appends the rewrite buffer to the new file and atomically renames it over the old AOF.

**Automatic rewrite** is controlled by:

```bash
redis-cli config get auto-aof-rewrite-percentage   # default: 100
redis-cli config get auto-aof-rewrite-min-size     # default: 64mb
```

AOF rewrite triggers when: AOF size > `auto-aof-rewrite-min-size` AND AOF has grown by `auto-aof-rewrite-percentage`% since the last rewrite. With defaults of 100%/64 MB, the first rewrite triggers when AOF exceeds 64 MB, then subsequent rewrites trigger each time the AOF doubles from the post-rewrite baseline.

### AOF file integrity

If Redis crashes mid-write, the AOF may end with a truncated record. On startup, Redis detects this:

```
aof-use-rdb-preamble yes   # default in Redis 7+; see hybrid section below
aof-load-truncated yes     # default: yes — ignore truncation and load what's valid
```

With `aof-load-truncated yes`, Redis loads up to the last complete command. The lost command is at most the one being written during the crash.

---

## Hybrid Persistence: RDB Preamble + AOF

Redis 4+ introduced a hybrid format where the AOF file starts with an RDB snapshot (fast to load) followed by AOF commands (recent changes):

```
┌──────────────────────────────────────────────────────────────────────┐
│  appendonly.aof  (hybrid format)                                     │
│                                                                      │
│  ┌─────────────────────────────────────────────────┐                 │
│  │  RDB preamble (compact binary snapshot)         │                 │
│  │  — all keys at the time of last AOF rewrite     │                 │
│  └─────────────────────────────────────────────────┘                 │
│  ┌─────────────────────────────────────────────────┐                 │
│  │  AOF tail (RESP commands since last rewrite)    │                 │
│  │  SET k1 v1\r\n                                  │                 │
│  │  INCR counter\r\n                               │                 │
│  │  ...                                            │                 │
│  └─────────────────────────────────────────────────┘                 │
└──────────────────────────────────────────────────────────────────────┘
```

Loading this file: Redis reads the RDB preamble (fast, binary, no command replay overhead), then replays only the AOF tail (short, since the last rewrite). This dramatically reduces restart time for large datasets.

Enable it:

```bash
redis-cli config set aof-use-rdb-preamble yes   # default: yes in Redis 7+
```

---

## Durability vs. Performance: Choosing a Mode

| Mode | Data loss risk | Write throughput | Restart speed | Best for |
|------|--------------|-----------------|---------------|---------|
| No persistence | All data on crash | Maximum | N/A | Ephemeral cache only |
| RDB only | Minutes of writes | Near-maximum | Fast (binary load) | Backup, cache-aside |
| AOF everysec | ~1 second | High | Slower (RESP replay) | Session store, leaderboards |
| AOF always | At most 1 write | Limited by fsync | Slower | Financial, audit logs |
| RDB + AOF everysec | ~1 second | High | Fast (hybrid) | Recommended default |
| RDB + AOF always | At most 1 write | Limited | Fast (hybrid) | Maximum durability |

**The Redis recommendation** for data you care about: `appendonly yes` + `appendfsync everysec` + `aof-use-rdb-preamble yes`. This gives you fast restarts, ~1-second durability, and manageable AOF size.

If you're using Redis purely as a cache (all data is regenerable from a primary DB), disable both: `save ""` + `appendonly no`. The performance gain is real and the risk is zero because all data is ephemeral by design.

---

## Restore Procedures

### Restoring from RDB

1. Stop Redis.
2. Copy your `dump.rdb` to the `dir` directory.
3. Start Redis. It loads the RDB on startup if AOF is disabled.

```bash
# If AOF is enabled, RDB is used as the preamble in hybrid mode.
# To force RDB-only load (e.g. from a backup):
redis-cli config set appendonly no
# restart Redis with the backup dump.rdb in place
```

### Restoring from AOF

```bash
# Validate AOF integrity before restoring (on a test instance):
redis-check-aof appendonly.aof
redis-check-aof --fix appendonly.aof    # truncate to last valid command

# Load it:
# Start Redis with appendonly yes pointing to the validated AOF.
```

### Restoring with hybrid

If the hybrid AOF is valid, just start Redis — it detects the RDB preamble automatically and loads it correctly.

### Testing your backups

```bash
# On a test host (not production):
redis-server --port 6380 --appendonly no --dbfilename dump-backup.rdb --dir /tmp/restore-test
redis-cli -p 6380 ping
redis-cli -p 6380 info keyspace
redis-cli -p 6380 dbsize
```

Never trust a backup you have not restored and validated. Schedule restore tests — at minimum monthly for critical data.

---

## Debugging: Fork Latency on Large Datasets

### Symptom

After `BGSAVE` or `BGREWRITEAOF` starts, all clients see a spike of 100+ ms latency, then return to normal.

### Diagnosis

```bash
# Check if a save is in progress:
redis-cli info persistence
# rdb_bgsave_in_progress:1
# rdb_last_bgsave_time_sec:0    <- less than 1 second means still saving

# Measure fork latency history:
redis-cli latency latest
# rdb-fork-diff-coe  3000  1714123456  500
# ^event             ^ms   ^timestamp  ^max_ms

redis-cli latency history rdb-fork-diff-coe

# Check RSS:
redis-cli info memory | grep rss
# used_memory_rss:10737418240  <- 10 GB RSS -> fork will take ~100-300ms
```

### Mitigations

**1. Transparent Huge Pages (THP) — the most common cause of abnormally large fork spikes**

THP merges 4 KB pages into 2 MB "huge pages" for performance. When the child process is writing the RDB and the main thread modifies data, COW occurs at the 2 MB granularity instead of 4 KB. A single write to a 2 MB page causes a 2 MB copy instead of 4 KB. This balloons memory usage during saves and amplifies fork latency:

```bash
cat /sys/kernel/mm/transparent_hugepage/enabled
# [always] madvise never

# Fix:
echo madvise > /sys/kernel/mm/transparent_hugepage/enabled
# or permanently in /etc/rc.local
```

Redis prints a warning on startup when THP is `always`. **This is the single most impactful Linux tuning for Redis.**

**2. Reduce RSS**

Keep instances smaller. Run multiple Redis instances instead of one large one. Rule of thumb: keep RSS under 2 GB per instance for manageable fork latency.

**3. Schedule saves during low-traffic windows**

```bash
# Disable automatic saves, schedule manually via cron at 03:00 UTC:
redis-cli config set save ""
# cron: 0 3 * * * redis-cli BGSAVE
```

**4. Use BGSAVE SCHEDULE**

`BGSAVE SCHEDULE` tells Redis to trigger a save *after* any ongoing AOF rewrite completes, avoiding concurrent save+rewrite:

```bash
redis-cli BGSAVE SCHEDULE
```

---

## Debugging: AOF Growth and Rewrite Not Triggering

### Symptom

The AOF file grows to gigabytes and the `aof_pending_rewrite` stat never clears.

### Diagnosis

```bash
redis-cli info persistence
# aof_enabled:1
# aof_rewrite_in_progress:0
# aof_rewrite_scheduled:0
# aof_current_size:4294967296     <- 4 GB
# aof_base_size:2147483648        <- last rewrite was 2 GB
# aof_pending_rewrite:0           <- no rewrite scheduled?!

# Check why rewrite isn't triggering:
redis-cli config get auto-aof-rewrite-percentage  # 100
redis-cli config get auto-aof-rewrite-min-size    # 67108864 (64 MB)
# 4 GB / 2 GB = 200% > 100% threshold
# So why no rewrite? Check if BGSAVE is in progress:
redis-cli info persistence | grep rdb_bgsave_in_progress
# rdb_bgsave_in_progress:1  <- blocked by concurrent BGSAVE
```

Redis will not run BGSAVE and BGREWRITEAOF simultaneously. If BGSAVE is running (from `save` triggers), the AOF rewrite is deferred. If saves are frequent and each save takes minutes, the AOF rewrite window never opens.

**Fix:**

```bash
# Option 1: Disable automatic RDB saves (use AOF only or hybrid)
redis-cli config set save ""

# Option 2: Trigger AOF rewrite explicitly after BGSAVE finishes
redis-cli BGSAVE SCHEDULE
redis-cli BGREWRITEAOF

# Option 3: Increase the rewrite-min-size threshold to avoid too-frequent rewrites
redis-cli config set auto-aof-rewrite-min-size 512mb
```

---

## Debugging: Data Loss Window

### Understanding what you actually lose

A common misconception: "I have AOF enabled, so I lose nothing." Reality: the loss window depends on `appendfsync`:

```bash
redis-cli info persistence | grep -E 'aof_delayed_fsync|aof_last_write_status|aof_current_rewrite_time_sec'
# aof_last_write_status:ok
# aof_delayed_fsync:0          <- non-zero means fsync fell behind

redis-cli config get appendfsync
# everysec                     <- up to ~1 second of data loss
```

If `aof_delayed_fsync` is non-zero and climbing, the disk cannot keep up with the `fsync` frequency. Your actual loss window is growing. Fixes: faster disk, `appendfsync no` (accept larger window), or reduce write rate.

### Simulating a crash to test recovery

```bash
# In a test environment:
redis-cli debug oom           # trigger OOM (causes crash, for testing)
redis-cli debug segfault      # force segfault, to test restart from AOF

# Then restart Redis and verify data:
redis-cli info keyspace
redis-cli dbsize
```

---

## Checkpoint

1. Explain exactly what happens in the OS kernel during `BGSAVE` that causes all clients to see a latency spike. How is the spike duration related to Redis's RSS?
2. You have `appendfsync everysec`. Redis crashes. How much data can you lose in the worst case? Why exactly 1 second and not 0 or 5 seconds?
3. What is copy-on-write in the context of `BGSAVE`? Draw (in text) what happens when the main thread modifies a key while the BGSAVE child is reading it.
4. Your Redis has a 20 GB RSS. You call `BGSAVE` during peak traffic. Estimate the fork latency spike. What is the single most impactful Linux configuration to check?
5. AOF rewrite is not triggering even though the AOF is 8× its post-rewrite size. List three reasons this could happen and how you'd check each.
6. The hybrid RDB+AOF format (`aof-use-rdb-preamble yes`) speeds up restart. Explain why. What does the RDB preamble contain and what does the AOF tail contain?
7. `SAVE` vs `BGSAVE`: when would you ever want to use `SAVE`? When would you never use it?
8. You need Redis to survive server reboots but can tolerate losing up to 5 minutes of data. What is the minimal persistence configuration?
9. How do you verify that an AOF file is intact before restoring it to a production instance?

→ Next up: **Memory & Eviction** — what happens when Redis runs out of memory, how to control it, and how key expiration actually works under the hood.
