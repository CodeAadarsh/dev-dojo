# Redis Architecture & the Event Loop

> **Module 01 · Course 19** — Redis is deceptively simple from the outside: send a command, get a result in microseconds. What makes that possible — and what can shatter it — lives in the single-threaded event loop and the RESP wire protocol. This module goes below the CLI and into the server internals.

You already know Redis as a fast key-value store. The goal here is to build the mental model that lets you reason about **latency, throughput, and failure modes** before they hit production — not after.

---

## The Big Picture: One Thread to Rule Them All

Every command you send to a Redis instance is executed by a **single main thread**. Not a thread pool. Not a worker queue with parallelism. One thread. This is the architectural decision that defines everything else about Redis behavior.

```
┌────────────────────────────────────────────────────────────────────────┐
│                         redis-server process                           │
│                                                                        │
│  ┌───────────────────────────────────────────────────────────────┐    │
│  │                        Main Thread                            │    │
│  │                                                               │    │
│  │   1. accept()  →  2. read() socket  →  3. parse RESP         │    │
│  │          ↓                                                    │    │
│  │   4. execute command (touches in-memory data store)           │    │
│  │          ↓                                                    │    │
│  │   5. build RESP reply  →  6. write() socket                  │    │
│  │                                                               │    │
│  │         ↑── all 6 steps are serialized, in order ──┘         │    │
│  └───────────────────────────────────────────────────────────────┘    │
│                                                                        │
│  ┌──────────┐  ┌──────────┐  ┌───────────────────────────────────┐   │
│  │ BIO I/O  │  │ BIO fsync│  │      lazyfree thread(s)           │   │
│  │ thread   │  │ thread   │  │  (async DEL, async eviction, etc.) │   │
│  └──────────┘  └──────────┘  └───────────────────────────────────┘   │
│  (background I/O threads — they do NOT touch the main data store)     │
└────────────────────────────────────────────────────────────────────────┘
```

The implication is stark: **if one command takes 200 ms to complete, every other client waits 200 ms for their turn**. There is no preemption. This is why O(1) and O(log N) commands are Redis's currency, and why `KEYS *` is the most dangerous thing you can run on a production instance.

### Where threads ARE used

Redis is not a single-threaded binary — it just has a single-threaded *command loop*. The actual process has several background threads:

| Thread | Purpose | Touches main data? |
|--------|---------|-------------------|
| Main thread | Command execution, event loop | Yes |
| BIO (background I/O) | Closing file descriptors, `fsync` for AOF | No |
| Lazyfree threads (2–3) | Async memory reclaim for large object deletes | Copies freed to a side queue; main thread detaches the object first |
| I/O threads (Redis 6+, optional) | Reading from and writing to client sockets | Yes, but gated by a lock; main thread still executes commands |

The lazyfree threads deserve special attention: when you issue `UNLINK key` (the async cousin of `DEL`), the main thread atomically removes the key from the dictionary so other commands can't reach it, then hands the actual memory reclaim to a lazyfree thread. This means the main thread's latency for `UNLINK` is O(1) regardless of value size — the cost is paid off the critical path.

Redis 6 added optional **threaded I/O** (`io-threads` config). When enabled, multiple threads handle socket reads/writes *concurrently*, while command execution remains serialized on the main thread. This is a network throughput optimization, not a parallelism of commands.

---

## The Event Loop: ae (Async Events)

Redis implements its own event loop called **ae** (async events), defined in `ae.c`. It does not use libevent, libuv, or Tokio — it wraps whatever multiplexer the OS provides:

```
┌─────────────────────────────────────────────────────────┐
│                      ae event loop                      │
│                                                         │
│  ┌─────────────────────────────────────────────────┐   │
│  │  select the OS multiplexer at compile time:     │   │
│  │  epoll (Linux) → kqueue (macOS/BSD) → select    │   │
│  └─────────────────────────────────────────────────┘   │
│                                                         │
│  loop forever:                                          │
│    1. aeProcessEvents()                                 │
│       a. calculate nearest timer deadline               │
│       b. epoll_wait(fd_set, timeout=nearest_timer)      │
│          → returns list of ready fds                    │
│       c. for each ready fd:                             │
│          - if it's the server socket: accept() new conn │
│          - if it's a client socket: readQueryFromClient │
│    2. processTimeEvents()                               │
│       - run expired timers (serverCron is the main one) │
└─────────────────────────────────────────────────────────┘
```

`serverCron` is a time event that fires roughly every 100 ms (configurable via `hz`). It handles housekeeping: expiring keys (active expiry sweep), replication heartbeats, AOF rewrites, bgsave scheduling, stats updates, and cluster state. The `hz` setting directly controls how frequently these sweeps happen — higher `hz` means more CPU spent on housekeeping, lower means coarser expiry precision.

### Reading a client command — step by step

When `epoll_wait` signals that a client socket is readable:

1. `readQueryFromClient()` calls `read()` into the client's input buffer.
2. The parser in `processInputBuffer()` parses RESP frames as they arrive. Frames may span multiple `read()` calls — Redis accumulates bytes until a full command is available.
3. Once a full command is parsed, `processCommand()` looks up the command name in the command table (a hash table of `redisCommand` structs).
4. The command's handler is called. It operates directly on the in-memory data store — no copying, no locking (no other thread touches it).
5. The reply is written into the client's output buffer.
6. The event loop registers the client's socket as writable, and on the next iteration calls `sendReplyToClient()`.

This means **throughput is fundamentally limited by command latency × requests per second**. Redis's sub-millisecond command execution is what makes 100K–1M QPS achievable on a single instance — not parallelism.

---

## RESP: the Redis Serialization Protocol

RESP (Redis Serialization Protocol) is the wire format between client and server. It is human-readable, text-based (with binary-safe strings), and trivially parseable.

Every RESP message starts with a type byte:

| Byte | Type | Example |
|------|------|---------|
| `+` | Simple string | `+OK\r\n` |
| `-` | Error | `-ERR unknown command\r\n` |
| `:` | Integer | `:1000\r\n` |
| `$` | Bulk string | `$6\r\nfoobar\r\n` |
| `*` | Array | `*2\r\n$3\r\nfoo\r\n$3\r\nbar\r\n` |

### Inline commands vs RESP requests

You can see RESP in action with nothing but `nc` or `telnet`:

```bash
# connect to a local Redis
nc 127.0.0.1 6379

# type an inline command (Redis tolerates this for simple cases):
PING
# response: +PONG

# type a proper RESP command (array of bulk strings):
*3
$3
SET
$3
foo
$3
bar
# response: +OK

*2
$3
GET
$3
foo
# response: $3
#           bar
```

A proper client (redis-py, Jedis, go-redis) always sends RESP arrays, never inline. The difference matters for pipelining.

### Pipelining and how it interacts with RESP

Because RESP is request-response over TCP, the round-trip time (RTT) is a real bottleneck for sequential single-command calls. Pipelining means sending multiple commands before reading any responses:

```
Without pipelining (4 RTTs):
  client ──► SET k1 v1 ──────────────────────► server
  client ◄── +OK ◄──────────────────────────── server
  client ──► SET k2 v2 ──────────────────────► server
  client ◄── +OK ◄──────────────────────────── server

With pipelining (1 RTT):
  client ──► SET k1 v1\r\nSET k2 v2\r\n ──► server
  client ◄── +OK\r\n+OK\r\n ◄────────────── server
```

The server processes pipelined commands one at a time in sequence — there is no concurrency. The gain is purely eliminating RTT between commands. For a cross-region client (say, 50 ms RTT) this is a 4× speedup for the 4-command batch above.

RESP3 (Redis 7+) adds push messages, which allows servers to proactively send invalidation notices. This enables **client-side caching** without polling.

---

## Why O(1) Commands Matter

The single-threaded model means every O(N) command adds N × (time per element) of latency to the queue tail. For Redis's typical sub-microsecond per-element operations, O(N) is fine if N is small. It becomes catastrophic when N is large.

### The complexity table you must internalize

| Command | Complexity | Safe on large N? |
|---------|-----------|-----------------|
| `GET`, `SET`, `INCR` | O(1) | Yes |
| `HGET`, `HSET` | O(1) | Yes |
| `LPUSH`, `RPUSH`, `LPOP`, `RPOP` | O(1) | Yes |
| `SADD`, `SREM`, `SISMEMBER` | O(1) | Yes |
| `ZADD`, `ZREM` | O(log N) | Yes |
| `ZRANGE` with `BYSCORE`/`BYLEX` | O(log N + M) | Yes, if M is small |
| `LRANGE key 0 -1` | O(N) | Only for small lists |
| `SMEMBERS` | O(N) | Only for small sets |
| `HGETALL` | O(N) | Only for small hashes |
| `SUNION`, `SDIFF`, `SINTER` | O(N×M) | Dangerous on large sets |
| `KEYS pattern` | O(N) — scans ALL keys | **Never in production** |
| `SORT` without `LIMIT` | O(N + M log M) | Dangerous |
| `FLUSHDB`, `FLUSHALL` | O(N) (sync mode) | Will block; use ASYNC |

The `KEYS` command scans every key in the keyspace on the main thread. On a 10 million key instance this takes hundreds of milliseconds, during which no other client gets a response. Always use `SCAN` instead.

### `SCAN` — the cursor-based O(1)-per-call alternative

```bash
# SCAN returns a cursor and a batch of keys.
# cursor 0 = start. When Redis returns cursor 0 again = you've seen all keys.

SCAN 0 MATCH "user:*" COUNT 100
# returns: 1) "3264"  (next cursor)
#          2) 1) "user:1001"
#             2) "user:4432"

SCAN 3264 MATCH "user:*" COUNT 100
# ...
# eventually returns: 1) "0"  (done)
```

`COUNT` is a hint, not a guarantee — Redis may return more or fewer keys. The full scan is not atomic; keys may appear or disappear between iterations. `SCAN` never blocks the event loop for more than the time to scan one hash table bucket batch.

---

## Latency Sources: Where Time Goes

Understanding where Redis latency originates helps you tune what matters and ignore what doesn't.

```
Total perceived latency = network RTT
                        + kernel socket overhead
                        + event loop iteration time
                        + command execution time
                        + reply serialization time
```

In practice, the breakdown for a well-tuned LAN deployment:

```
┌──────────────────────────────────────────────────────────────────┐
│ Component              │ Typical (LAN)   │ When it blows up      │
├──────────────────────────────────────────────────────────────────┤
│ Network RTT            │ 0.1–0.5 ms      │ Cross-region: 50+ ms  │
│ Kernel socket overhead │ 5–20 µs         │ Noisy neighbor, NUMA  │
│ Event loop iteration   │ 1–5 µs          │ High hz + many timers │
│ Command execution      │ 1–100 µs        │ O(N) command, O(N>1M) │
│ fork() for BGSAVE      │ 50–500 ms spike │ Large memory RSS       │
│ AOF fsync (always)     │ 1–10 ms/write   │ Slow disk, SSD wear   │
└──────────────────────────────────────────────────────────────────┘
```

### The fork latency spike

The BGSAVE and BGREWRITEAOF commands both call `fork()`. On Linux, `fork()` is copy-on-write at the page-table level, but the main thread still has to set up the page-table copy for the child — and this takes time proportional to the process's RSS.

A Redis instance with 10 GB RSS on a modern Linux can take **50–200 ms** in `fork()` during which the main thread is stalled. This shows up as a latency spike on all clients. The fix is either smaller RSS (more instances), or using `BGSAVE` during low-traffic windows.

Monitor this:

```bash
redis-cli info stats | grep rdb_last_bgsave_time_sec
redis-cli info latency   # requires latency monitoring enabled
redis-cli --latency      # real-time latency histogram
redis-cli --latency-history -i 5  # sampled every 5 seconds
```

---

## Debugging: Slow Commands Blocking Everything

### Symptom

All clients suddenly experience 100+ ms latency spikes. The spikes are correlated — all clients wait together, not independently. This is the hallmark of a blocked event loop.

### Diagnosis

**Step 1: SLOWLOG**

```bash
# Enable slowlog (default threshold: 10000 µs = 10 ms)
redis-cli config set slowlog-log-slower-than 1000   # 1 ms threshold

# After a spike:
redis-cli slowlog get 10
# Output:
# 1) 1) (integer) 42           <- entry ID
#    2) (integer) 1714123456   <- unix timestamp
#    3) (integer) 215000       <- duration in microseconds (215 ms!)
#    4) 1) "KEYS"              <- the command
#       2) "*"
```

The slowlog is stored in memory as a circular buffer (`slowlog-max-len`, default 128). It never touches disk. Duration in the slowlog is **command execution time only** — network RTT is not included. So 215 ms in slowlog means 215 ms with the event loop held.

**Step 2: LATENCY MONITOR**

Redis has a built-in latency monitor (Redis 2.8.13+):

```bash
redis-cli config set latency-monitor-threshold 10   # report events > 10 ms
redis-cli latency latest         # most recent latency per event name
redis-cli latency history event  # time series
redis-cli latency reset
```

Event names include `command` (a slow command), `fast-command`, `aof-stat`, `rdb-fork-diff-coe`.

**Step 3: CLIENT LIST to find the offender**

```bash
redis-cli client list
# id=42 addr=10.0.1.5:51234 fd=12 name=analytics cmd=keys age=1 idle=0 ...
```

The `cmd` field shows the last command issued by each client. A client that's been running `KEYS` or `SMEMBERS` on a huge set for 200 ms will show exactly that.

**Step 4: Real-time monitoring**

```bash
redis-cli monitor   # streams every command as it executes
# WARNING: MONITOR itself has overhead — use only for brief diagnosis
```

`MONITOR` is the most powerful and most dangerous diagnostic tool. It echoes every command to your terminal in real time, but this comes at a cost: for high-QPS instances, `MONITOR` itself can slow the server by 50%.

### Mitigations

| Problem | Fix |
|---------|-----|
| `KEYS *` in production | Replace with `SCAN`; add lint check to CI |
| `SMEMBERS` on huge set | Use `SSCAN`; or redesign data model with sorted sets + `ZRANGEBYSCORE` |
| `SORT` without `LIMIT` | Always add `LIMIT 0 N`; use a sorted set instead |
| `LRANGE key 0 -1` | Paginate; set max list size via `LTRIM` on write |
| `FLUSHDB` blocking | Use `FLUSHDB ASYNC` (Redis 4+); paginate SCAN+DEL |

### Latency spikes from fork

```bash
redis-cli info persistence | grep rdb_last_bgsave_time_sec
# rdb_last_bgsave_time_sec:3   <- 3 seconds to last bgsave (alarming for LAN)

# check if transparent hugepages are causing fork slowness (Linux):
cat /sys/kernel/mm/transparent_hugepage/enabled
# if 'always', switch to 'madvise' to reduce COW overhead during fork
echo madvise > /sys/kernel/mm/transparent_hugepage/enabled
```

Redis will also log a warning on startup if THP is enabled: look for `WARNING you have Transparent Huge Pages (THP) support enabled in your kernel`.

---

## The Command Table and Flags

Every Redis command is registered in a command table with metadata:

```
SET   flags=wmF   arity=-3   first_key=1  last_key=1  step=1
GET   flags=rF    arity=2    first_key=1  last_key=1  step=1
KEYS  flags=rS    arity=2    first_key=0  last_key=0  step=0
```

The flags are:
- `w` — write command (modifies data)
- `r` — read-only command
- `m` — may increase memory usage
- `F` — fast command (expected O(1) or O(log N))
- `S` — sort command / `SCAN`-like
- `a` — admin command
- `l` — loading command (allowed even if server is loading RDB)

You can query them:

```bash
redis-cli command info set get keys
```

The `COMMAND DOCS` and `COMMAND INFO` family is the built-in reference. In Redis 7+, `COMMAND GETKEYS` tells you which arguments are key names, which matters for cluster key routing.

---

## RESP3 and Client-Side Caching

Redis 7 promoted RESP3, which adds:

- **Push messages**: server can push data to the client without a request (used for pub/sub, keyspace notifications, and client-side cache invalidation).
- **Attribute types**: metadata attached to a reply.
- **Map, Set, Double, Blob error, Verbatim string** native types, so clients don't have to guess types.

Client-side caching with RESP3:

```
Client                     Server
  |── HELLO 3 ──────────────────────► (upgrade to RESP3)
  |── CLIENT TRACKING on ───────────► (subscribe to invalidation)
  |── GET product:42 ────────────────► 
  |◄─ "...price data..." ─────────────
  |   [client caches locally]
  |
  |   [another client writes SET product:42 ...]
  |
  |◄─ push: invalidate [product:42] ── (server sends unsolicited push)
  |   [client evicts local cache entry]
  |── GET product:42 ────────────────►
  |◄─ "...new price data..." ──────────
```

Client-side caching eliminates the network round-trip for reads when data hasn't changed. For read-heavy workloads (product catalog, feature flags, rate limit config), this is a significant multiplier.

---

## Debugging: Latency Spikes That Aren't Commands

Not every latency spike is a slow command. Other causes:

### OS-level: CPU scheduling jitter

On a noisy multi-tenant VM, the Redis process can be preempted mid-loop. Use `redis-cli --intrinsic-latency 60` to measure the baseline jitter of the OS itself (run for 60 seconds):

```bash
redis-cli --intrinsic-latency 60
# Max latency so far: 1 microseconds.
# Max latency so far: 42 microseconds.
# Max latency so far: 819 microseconds.  <- OS preemption event
```

If intrinsic latency is high (>500 µs), the OS is the problem, not Redis. On Linux, check CPU governor, NUMA topology, and scheduler isolation (`isolcpus`, `taskset`).

### AOF fsync blocking the BIO thread

When `appendfsync everysec`, the BIO thread calls `fsync()` once per second. On a heavily loaded or slow disk, if that `fsync()` takes more than 2 seconds, Redis detects the stall and postpones the next write — which means clients waiting for write confirmation see extra latency.

```bash
redis-cli info persistence | grep -E 'aof_delayed_fsync|aof_last_write_status'
# aof_delayed_fsync:42      <- number of times the main thread delayed due to fsync
```

### Fork for BGSAVE during peak traffic

```bash
redis-cli debug sleep 0.5   # simulate a 500ms block (test in non-prod!)
redis-cli info stats | grep rdb_last_bgsave_time_sec
```

Schedule BGSAVE with `BGSAVE SCHEDULE` (Redis 3.2+) to defer it until after any currently running AOF rewrite completes.

---

## Checkpoint

Before moving on, you should be able to answer all of these without looking anything up:

1. What is the one condition that makes a Redis O(N) command dangerous? Why?
2. A Redis instance with 10 clients suddenly shows all clients experiencing 200 ms latency spikes simultaneously. What is the most likely cause, and what is your first diagnostic command?
3. How does `UNLINK` differ from `DEL` at the thread level? When would you choose one over the other?
4. Draw the RESP encoding of the command `SET greeting "hello world"`.
5. What does `redis-cli --intrinsic-latency 60` measure, and why run it before blaming Redis for latency?
6. What is the purpose of `serverCron`, and what does the `hz` config control?
7. A developer asks if it's safe to use `MONITOR` on a 200K QPS production instance for an hour. What do you say?
8. Explain what happens in the Redis server during the `fork()` call for BGSAVE, and why it shows up as a latency spike on all connected clients.
9. What problem does RESP3 client-side caching solve, and what Redis server feature makes it work without polling?

→ Next up: **Data Types & Encodings** — how Redis stores your data internally and why choosing the wrong data type or hitting an encoding threshold can silently multiply your memory usage.
