# Transactions, Scripting & Patterns

> **Module 07 · Course 19** — Redis is single-threaded. That's both its constraint and its superpower: if you can get your read-modify-write into a single, atomic operation, no other client can interleave. This module covers the three mechanisms that give you atomicity — MULTI/EXEC, Lua scripting, and pipelining — and then applies them to the six canonical patterns you'll encounter in almost every production backend.

The patterns section is deliberately long. You can look up syntax; you cannot look up *which pattern is appropriate for which problem* under pressure. Work through each one.

---

## 1. MULTI / EXEC — Transactions

### 1.1 The Model

Redis transactions queue a sequence of commands on the client connection and execute them as an atomic block. "Atomic" here means **no other client command will interleave** — it is not a transactional in the database sense (no rollback on partial failure).

```
  Client                          Redis
    │                               │
    │  MULTI                        │
    │  ──────────────────────────►  │  "transaction started"
    │                               │
    │  INCR views:article:42        │
    │  ──────────────────────────►  │  QUEUED
    │                               │
    │  ZADD leaderboard 1 user:42   │
    │  ──────────────────────────►  │  QUEUED
    │                               │
    │  EXEC                         │
    │  ──────────────────────────►  │  executes both atomically
    │                               │  returns: [1, 1]
    │  ◄──────────────────────────  │
```

Between `MULTI` and `EXEC`, Redis only queues the commands — it does not execute them. Other clients can still run commands against the server in between, but none of those will interleave with your queued block when `EXEC` fires.

```bash
MULTI
INCR views:article:42
ZADD leaderboard 1 user:42
EXEC
# returns: 1) (integer) 1
#          2) (integer) 1
```

`DISCARD` aborts a queued transaction:

```bash
MULTI
SET foo bar
DISCARD    # queue discarded, no commands executed
```

### 1.2 Error Handling in Transactions

There are two kinds of errors in a transaction:

**Command error at queue time** (syntax error, wrong argument count):
```bash
MULTI
SET foo              # wrong arg count
# returns: -ERR wrong number of arguments for 'set' command
EXEC
# returns: -EXECABORT Transaction discarded because of previous errors.
```
The entire transaction is aborted.

**Runtime error during EXEC** (wrong type on operation):
```bash
MULTI
SET foo "bar"
INCR foo             # foo is a string, not an integer
SET baz "qux"
EXEC
# returns: 1) OK
#          2) -ERR value is not an integer or out of range
#          3) OK
```
Only the failing command returns an error — the others execute normally. **Redis does NOT roll back on runtime errors.** This is by design and a well-known footgun: there is no ROLLBACK command. You must account for partial execution in your application logic.

### 1.3 WATCH — Optimistic Locking

`WATCH` is how you implement compare-and-set: watch a key, read its value, compute a new value, then execute a transaction that only commits if the key was not modified by anyone else in the meantime.

```bash
WATCH balance:user:42

val = GET balance:user:42
# application logic: compute new balance
new_val = val - 100

MULTI
SET balance:user:42 $new_val
EXEC
# If balance:user:42 changed since WATCH: EXEC returns nil (transaction aborted)
# If it was not modified: EXEC returns the result array
```

```
  Client A                       Client B              Redis
    │                                │                    │
    │  WATCH balance:user:42         │                    │
    │  ─────────────────────────────────────────────────► │
    │  GET balance:user:42           │                    │
    │  ─────────────────────────────────────────────────► │
    │  ◄──── "500" ──────────────────│──────────────────  │
    │                                │                    │
    │                                │  SET balance:user:42 400  │
    │                                │  ───────────────────────► │
    │                                │  ◄─── OK ────────────── │
    │  MULTI                         │                    │
    │  SET balance:user:42 400       │                    │
    │  EXEC                          │                    │
    │  ─────────────────────────────────────────────────► │
    │  ◄──── (nil)  (aborted)  ──────│──────────────────  │
    │  (retry the whole sequence)     │                    │
```

The retry loop pattern in application code:

```python
import redis

def deduct_balance(r: redis.Redis, user_id: int, amount: int) -> bool:
    key = f"balance:user:{user_id}"
    with r.pipeline() as pipe:
        while True:
            try:
                pipe.watch(key)
                balance = int(pipe.get(key) or 0)
                if balance < amount:
                    pipe.reset()
                    return False
                pipe.multi()
                pipe.set(key, balance - amount)
                pipe.execute()
                return True
            except redis.WatchError:
                continue  # retry on concurrent modification
```

WATCH has a scope: it is cleared on `EXEC`, `DISCARD`, or connection close. Watching many keys increases contention — under high concurrency, `WATCH` retry loops can spin. That's when Lua scripts are the better answer.

---

## 2. Lua Scripting — True Atomicity

### 2.1 Why Lua Beats MULTI/EXEC for Complex Logic

`MULTI/EXEC` queues commands but **cannot branch** — you cannot do `IF result_of_GET > threshold THEN incr`. Lua scripts run on the Redis server in a single, non-preemptible step. Because Redis is single-threaded, no other command executes while Lua is running — full atomicity with conditional logic.

```
  redis-server
  ┌─────────────────────────────────────────────────────┐
  │  event loop                                          │
  │    …                                                 │
  │    execute command: EVAL "..."                       │
  │    ┌──────────────────────────────────────────────┐  │
  │    │  Lua VM runs (no other commands execute)      │  │
  │    │  redis.call("GET", KEYS[1])                   │  │
  │    │  redis.call("SET", KEYS[1], ...)              │  │
  │    └──────────────────────────────────────────────┘  │
  │    resume event loop                                 │
  └─────────────────────────────────────────────────────┘
```

### 2.2 EVAL and EVALSHA

```bash
EVAL script numkeys [key ...] [arg ...]
```

`KEYS` and `ARGV` are the two Lua tables available inside the script. `KEYS` holds the key names (helps Redis Cluster determine which shard to route to); `ARGV` holds arbitrary arguments.

```bash
# Atomic increment with floor — never go below 0:
EVAL "
  local val = tonumber(redis.call('GET', KEYS[1])) or 0
  if val > 0 then
    val = val - tonumber(ARGV[1])
    if val < 0 then val = 0 end
    redis.call('SET', KEYS[1], val)
  end
  return val
" 1 balance:user:42 100
```

`EVALSHA` executes a pre-loaded script by its SHA1 digest — faster because it skips network transfer of the script body:

```bash
# Load the script once:
SCRIPT LOAD "return redis.call('GET', KEYS[1])"
# returns: "b8059ff43d2db75c87a90cf703d478cf1fd18501"

# Execute by hash:
EVALSHA b8059ff43d2db75c87a90cf703d478cf1fd18501 1 mykey
```

`SCRIPT EXISTS <sha1>`: check if a script is cached.
`SCRIPT FLUSH`: clear all cached scripts (use after a Redis restart).
`SCRIPT KILL`: terminate a running script (only if it has not yet written anything — otherwise you'd leave the server in a partial state).

### 2.3 Lua Error Handling

Two forms of `redis.call` vs `redis.pcall`:

```lua
-- redis.call propagates errors up (EVAL returns an error to the client)
local val = redis.call('GET', KEYS[1])

-- redis.pcall catches errors (returns a Lua table with err field)
local ok, err = pcall(function()
  return redis.call('INCR', KEYS[1])
end)
if err then
  return redis.error_reply("increment failed: " .. tostring(err))
end
```

Return types from Lua → Redis:
- Lua number → integer reply
- Lua string → bulk string reply
- Lua table → multi-bulk reply
- `redis.status_reply("OK")` → status reply
- `redis.error_reply("ERR msg")` → error reply
- `false` → nil bulk reply

### 2.4 Redis Functions (Redis 7.0+)

Functions supersede EVALSHA for production Lua: they are named, versioned, and persist across restarts without re-loading.

```bash
FUNCTION LOAD "#!lua name=mylib\n local function incr(keys, args)\n   return redis.call('INCR', keys[1])\n end\n redis.register_function('myincr', incr)"

FCALL myincr 1 counter:hits
```

For Redis < 7, `EVALSHA` + script load in application startup is the pattern. For Redis 7+, Functions are the right path for shared business logic in scripts.

---

## 3. Pipelining vs Transactions

These are often confused. They are orthogonal mechanisms:

| Mechanism | Purpose | Atomicity | Conditionals |
|-----------|---------|-----------|--------------|
| Pipelining | Batch multiple commands into one TCP round trip | No | No |
| MULTI/EXEC | Execute a queued command block without interleaving | Yes (no rollback) | No |
| Lua EVAL | Run arbitrary logic on the server atomically | Yes | Yes |

**Pipelining** batches commands to reduce round-trip latency — the client sends all commands in one write, and reads all responses in one read. It does not guarantee anything about interleaving:

```python
pipe = r.pipeline(transaction=False)   # pure pipelining, no MULTI/EXEC
pipe.set("foo", "bar")
pipe.incr("counter")
pipe.get("foo")
results = pipe.execute()               # [True, 1, b'bar']
```

`transaction=True` (the default in redis-py) wraps the pipeline in `MULTI/EXEC`. Use `transaction=False` when you only care about round-trip efficiency, not atomicity.

**The golden rule**: use pipelining for throughput, MULTI/EXEC for atomicity without conditionals, Lua for atomicity with conditionals.

---

## 4. Canonical Patterns

### 4.1 Cache-Aside (Lazy Loading)

The most common pattern: the application checks Redis first; on a miss, fetches from the database and populates the cache.

```
  Client
    │
    │  GET user:42
    ▼
  Redis ── hit ──► return cached value
    │ miss
    ▼
  Database (e.g., PostgreSQL)
    │
    │  SELECT * FROM users WHERE id = 42
    ▼
  Application
    │
    │  SETEX user:42 3600 <serialized_value>  (write to cache with TTL)
    │
    └──► return value to client
```

```python
def get_user(r: redis.Redis, db, user_id: int):
    key = f"user:{user_id}"
    cached = r.get(key)
    if cached:
        return deserialize(cached)
    row = db.execute("SELECT * FROM users WHERE id = %s", user_id).fetchone()
    if row:
        r.setex(key, 3600, serialize(row))   # 1-hour TTL
    return row
```

Cache-aside is **read-heavy optimized** and **eventually consistent**: the cache may serve stale data between a DB write and the TTL expiry. The TTL is your staleness budget.

**Cache invalidation on write**: explicitly delete the cache key on every write:

```python
def update_user(r, db, user_id, data):
    db.execute("UPDATE users SET ... WHERE id = %s", user_id)
    r.delete(f"user:{user_id}")   # invalidate; next read will miss and repopulate
```

Never write the new value to cache in the same write transaction — you risk writing a stale value if the DB transaction rolls back.

### 4.2 Write-Through

In write-through, the application writes to Redis and the database *synchronously*, in the same write path. The cache is never stale.

```python
def update_user_write_through(r, db, user_id, data):
    db.execute("UPDATE users SET ... WHERE id = %s", user_id)
    # only update cache after DB commit
    r.setex(f"user:{user_id}", 3600, serialize(data))
```

The risk: if the DB write succeeds but the Redis write fails, you have divergence. Mitigate by: (a) tolerating the divergence (cache will miss, DB will be read on next request), or (b) using a write queue that retries.

Write-through is appropriate when reads are hot and writes are infrequent. For write-heavy workloads, the extra Redis write per DB write may not be worth it — cache-aside's lazy population is cheaper.

### 4.3 Rate Limiting — Sliding Window with Sorted Set

A sorted set where the score is the request timestamp implements a sliding window with O(log N) per request:

```lua
-- rate_limit.lua: atomic sliding window
-- KEYS[1] = rate limit key (e.g., "ratelimit:user:42:POST /api/order")
-- ARGV[1] = current timestamp (ms)
-- ARGV[2] = window size (ms)
-- ARGV[3] = max requests in window
-- Returns: 1 = allowed, 0 = denied

local key    = KEYS[1]
local now    = tonumber(ARGV[1])
local window = tonumber(ARGV[2])
local limit  = tonumber(ARGV[3])

redis.call('ZREMRANGEBYSCORE', key, '-inf', now - window)  -- prune old entries
local count = redis.call('ZCARD', key)
if count < limit then
  redis.call('ZADD', key, now, now .. math.random())       -- unique member
  redis.call('PEXPIRE', key, window)
  return 1
else
  return 0
end
```

```bash
# Allowed: 100 requests per 60 seconds for user 42
EVAL "$(cat rate_limit.lua)" 1 "ratelimit:user:42" 1700000001000 60000 100
# -> 1 (allowed)
```

The fixed-window alternative (`INCR key; EXPIRE key 60`) is simpler but has a boundary burst problem: a user can make 100 requests at 00:59 and 100 more at 01:01 — 200 in 2 seconds. The sliding window closes this gap.

### 4.4 Distributed Lock — SET NX PX + Lua Release

The canonical pattern for a distributed mutex using Redis:

```bash
# Acquire: SET if Not eXists, with expiry (prevents deadlock on crash)
SET lock:resource:42 <unique_token> NX PX 30000
# NX = only set if key does not exist
# PX 30000 = auto-expire in 30 seconds (your worst-case processing time)
# Returns: OK (acquired) or nil (someone else holds it)
```

The unique token (UUID or ULID) is critical — it's how you verify you still own the lock before releasing it. Without it, you might release someone else's lock.

**Release via Lua (atomic check-and-delete):**

```lua
-- release_lock.lua
-- KEYS[1] = lock key
-- ARGV[1] = token we set when acquiring
if redis.call("GET", KEYS[1]) == ARGV[1] then
  return redis.call("DEL", KEYS[1])
else
  return 0
end
```

Why Lua? The naive code `if GET lock == my_token: DEL lock` has a TOCTOU race: between GET and DEL, the lock could expire and be reacquired by another client. Lua makes the check-and-delete atomic.

```python
LOCK_SCRIPT = """
if redis.call("GET", KEYS[1]) == ARGV[1] then
  return redis.call("DEL", KEYS[1])
else
  return 0
end
"""

def release_lock(r, key, token):
    return r.eval(LOCK_SCRIPT, 1, key, token)

def with_lock(r, key, ttl_ms, fn):
    import uuid
    token = str(uuid.uuid4())
    acquired = r.set(key, token, nx=True, px=ttl_ms)
    if not acquired:
        raise RuntimeError("Could not acquire lock")
    try:
        return fn()
    finally:
        release_lock(r, key, token)
```

> **Redlock caveats.** Redlock (acquire the lock on N/2+1 independent Redis nodes) is often cited as a stronger distributed lock. It has well-documented weaknesses: clock skew between nodes, GC pauses causing a client to believe it holds the lock past expiry, and network partitions causing split-lock situations. For most use cases, a single-node lock with a reasonable TTL and idempotent processing is safer and simpler than Redlock. If you truly need a distributed lock with strong guarantees, consider ZooKeeper or etcd — they are consensus systems designed for this.

### 4.5 Leaderboard — Sorted Set

Sorted sets (`ZSET`) score members by a floating-point value and maintain order in O(log N):

```bash
# Add or update a player's score:
ZADD leaderboard 2450 "user:42"
ZADD leaderboard 3100 "user:99"
ZADD leaderboard 1800 "user:17"

# Top 10 by score (descending):
ZREVRANGE leaderboard 0 9 WITHSCORES

# Rank of a specific player (0-indexed, descending):
ZREVRANK leaderboard "user:42"
# -> 1  (second place)

# Score of a player:
ZSCORE leaderboard "user:42"
# -> "2450"

# Players within a score range:
ZRANGEBYSCORE leaderboard 2000 3000 WITHSCORES

# Increment score atomically (atomic — no read-modify-write needed):
ZINCRBY leaderboard 50 "user:42"
# -> "2500"
```

For paginated leaderboards:

```bash
# Page 2 (entries 10-19, descending):
ZREVRANGE leaderboard 10 19 WITHSCORES

# ZREVRANGEBYSCORE with LIMIT for score-based pagination:
ZREVRANGEBYSCORE leaderboard 2499 -inf LIMIT 0 10 WITHSCORES
# "give me the next 10 entries with score < 2500" (cursor pagination)
```

Time-based decay: combine with a scheduled job that applies a multiplier to all scores periodically:

```bash
# Halve all scores (for decay over time) — use ZRANGEBYSCORE + ZADD in a pipeline:
members = ZRANGE leaderboard 0 -1 WITHSCORES
pipeline:
  for member, score in members:
    ZADD leaderboard (score * 0.5) member
```

For very large leaderboards (millions of entries), a Cluster-sharded approach using hash tags per score range is needed.

### 4.6 Reliable Queue — Streams

The Streams consumer group pattern from Module 06 is the correct Redis queue implementation. Here is the complete worker loop in one place:

```python
import redis
import time

r = redis.Redis(host="localhost", port=6399, decode_responses=True)
STREAM = "events:orders"
GROUP  = "billing"
CONSUMER = "worker-1"

# Ensure group exists:
try:
    r.xgroup_create(STREAM, GROUP, id="0", mkstream=True)
except redis.ResponseError as e:
    if "BUSYGROUP" not in str(e):
        raise

def process(entry_id, data):
    # your business logic here — must be idempotent
    print(f"processing {entry_id}: {data}")

def worker():
    # Phase 1: drain own PEL (entries from before last restart)
    while True:
        entries = r.xreadgroup(GROUP, CONSUMER, {STREAM: "0"}, count=50)
        if not entries or not entries[0][1]:
            break
        for stream_name, messages in entries:
            for msg_id, data in messages:
                process(msg_id, data)
                r.xack(STREAM, GROUP, msg_id)

    # Phase 2: consume new entries
    while True:
        entries = r.xreadgroup(GROUP, CONSUMER, {STREAM: ">"}, block=2000, count=50)
        if entries:
            for stream_name, messages in entries:
                for msg_id, data in messages:
                    try:
                        process(msg_id, data)
                        r.xack(STREAM, GROUP, msg_id)
                    except Exception as e:
                        print(f"WARN: processing failed for {msg_id}: {e}")
                        # do NOT ack — it stays in PEL for retry/DLQ handling

        # Phase 3: reclaim entries from dead workers
        result = r.xautoclaim(STREAM, GROUP, CONSUMER, min_idle_time=30000, start_id="0-0", count=50)
        next_id, claimed, _ = result
        for msg_id, data in claimed:
            process(msg_id, data)
            r.xack(STREAM, GROUP, msg_id)

worker()
```

---

## Debugging Transactions, Scripts & Pipelines

### Non-Atomic Check-Then-Set

The bug: reading a value and conditionally writing based on it outside of a transaction or script.

```python
# WRONG — race condition between GET and SET
val = r.get("inventory:item:42")
if int(val) > 0:
    r.decr("inventory:item:42")  # another client may have decremented already!
```

Fix with WATCH/MULTI/EXEC:
```python
with r.pipeline() as pipe:
    while True:
        try:
            pipe.watch("inventory:item:42")
            val = int(pipe.get("inventory:item:42") or 0)
            if val <= 0:
                pipe.reset(); break
            pipe.multi()
            pipe.decr("inventory:item:42")
            pipe.execute()
            break
        except redis.WatchError:
            continue
```

Or better, a Lua script that avoids the retry loop entirely:

```lua
local val = tonumber(redis.call('GET', KEYS[1])) or 0
if val > 0 then
  return redis.call('DECR', KEYS[1])
else
  return redis.error_reply('OUT_OF_STOCK')
end
```

### Unsafe Lock Release — The TOCTOU Bug

```python
# WRONG — not atomic
token = r.get("lock:resource:42")
if token == my_token:
    r.delete("lock:resource:42")  # lock could expire and be reacquired between GET and DEL
```

The Lua script in section 4.4 is the fix. Always use the atomic check-and-delete for lock release.

Diagnosing a lock that is never releasing (leaked lock):

```bash
# Check if the lock key exists and its TTL:
EXISTS lock:resource:42
TTL lock:resource:42   # -1 = no expiry (bug: lock created without PX/EX)
GET lock:resource:42   # what token holds it?

# If TTL is -1, the lock has no expiry — it will never auto-release on crash
# Fix: always SET lock ... NX PX <ttl>
```

### Pipeline Error Handling

Pipelines in redis-py raise an exception on the first error by default, discarding subsequent results. To get all results including errors:

```python
pipe = r.pipeline(raise_on_error=False)
pipe.set("foo", "bar")
pipe.incr("not_an_int_key")   # this will error at runtime
pipe.get("foo")
results = pipe.execute(raise_on_error=False)
# results: [True, ResponseError(...), b'bar']
# Inspect results individually
```

In `MULTI/EXEC` pipelines, the EXEC response contains per-command results — error in one command does not abort others (runtime error) unless the queue itself errored (syntax error → EXECABORT).

### Diagnosing Script Timeout

A Lua script that runs too long blocks the entire Redis event loop:

```bash
redis-cli INFO server | grep lua_time_limit
# default: 5000 ms

# If a script is currently running and over the limit:
redis-cli DEBUG SLEEP 0  # this will block until the script finishes or is killed
redis-cli SCRIPT KILL    # kills a running script only if it hasn't written anything
                          # if it has written: SHUTDOWN NOSAVE is the nuclear option
```

Long-running Lua scripts are a production risk. If your script processes a variable number of keys, cap it (e.g., process 100 keys max per call and call again in a loop).

### DEBUG and Monitoring

```bash
# Watch all commands in real time (use carefully in production — high volume):
redis-cli MONITOR

# Log slow commands (latency profiling):
redis-cli CONFIG SET slowlog-log-slower-than 10000   # 10ms threshold
redis-cli SLOWLOG GET 25                             # last 25 slow commands
redis-cli SLOWLOG RESET

# Latency histogram:
redis-cli LATENCY HISTORY event
redis-cli LATENCY LATEST
```

---

## Checkpoint

Answer without notes:

1. `MULTI; INCR foo; INCR not_an_integer; INCR bar; EXEC` — what is the return value? Which commands executed?
2. Why does `MULTI/EXEC` not support conditional logic (`IF value > 0 THEN ...`)? What is the alternative?
3. Explain the TOCTOU race in a naive lock release (`GET; compare; DEL`). Why does Lua eliminate it?
4. A `SET lock NX PX 30000` returns `nil`. What are two legitimate reasons this could happen?
5. You have a Redis Sorted Set for a leaderboard. A player's score should increase atomically — what single command does this without a read-modify-write?
6. Sketch the sliding-window rate limiter: which Redis data structure, what does ZREMRANGEBYSCORE do, and why must the entire operation be in a Lua script?
7. `pipeline(transaction=False)` vs `pipeline(transaction=True)` in redis-py — what is the wire-level difference? When do you prefer each?
8. A consumer processes a Stream entry, then crashes before `XACK`. What happens to that entry? How does the watchdog detect and recover it, and what invariant must the processing function satisfy for this to be safe?
9. Your Lua script holds a lock, reads a value, conditionally updates three keys, and releases the lock. The script has been running for 6 seconds. What happens on the server, and what should the calling client do?

➡ You have completed the Redis internals sequence. The challenges that follow will put every concept from modules 01–07 under operational pressure.
