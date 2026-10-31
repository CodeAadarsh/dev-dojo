# Concurrency & Reliability

> **Module 05 · Course 10** — A service that works under low load and falls over under high load isn't reliable; it's just untested. This module covers the concurrency primitives that separate thread-safe code from race conditions, and the reliability patterns — circuit breakers, bulkheads, backoff, rate limiters — that keep one misbehaving dependency from cascading into a full outage.

If you've built services in Java or Node.js, you've used threads or an event loop without necessarily understanding the guarantees each model gives you. The first half of this module is that foundation; the second half is the production reliability toolkit.

---

## Threads vs async/event-loop

Two fundamentally different concurrency models, with different strengths:

```
THREAD-PER-REQUEST (Java/Spring, Python threading)

  Request 1 → Thread 1 [   DB query   ] [JSON serialize] → Response
  Request 2 → Thread 2 [DB query] [                     ] → Response
  Request 3 → Thread 3 [            DB query             ] → Response

  Each thread blocks while waiting for I/O.
  OS scheduler preempts threads, context-switches cost ~1–10µs.
  Typical: 200–500 concurrent threads before contention matters.

EVENT LOOP (Node.js, Python asyncio, libuv)

  Event loop (single thread):
    poll I/O → dispatch callback → poll I/O → dispatch callback → ...

  Request 1 → send DB query → register callback → yield
  Request 2 → send DB query → register callback → yield
  (DB response 1) → resume handler 1 → respond
  (DB response 2) → resume handler 2 → respond

  One thread handles thousands of concurrent I/O operations.
  No context-switching overhead.
  CPU-bound work BLOCKS the loop (no preemption).
```

**Goroutines (Go): M:N threading.** The Go runtime maps M goroutines onto N OS threads. Goroutines are ~2KB of stack (vs ~1MB for OS threads), making 100k goroutines feasible. The scheduler is cooperative+preemptive (since Go 1.14, goroutines can be preempted at function call points). This is why Go HTTP servers handle concurrency that would OOM a Java server on the same RAM.

When to pick each:

| Model | Wins when | Loses when |
|-------|-----------|------------|
| Threads | CPU-bound work; libraries aren't async-safe; team comes from Java/Go | Many concurrent I/O-bound requests; high concurrency on limited RAM |
| Event loop | I/O-bound service with high request volume; Node.js team | Any CPU-heavy computation on the hot path (blocks the loop) |
| Goroutines | Mixed CPU+I/O; need high concurrency without async syntax overhead | Existing codebase in Java/Python; goroutine leaks are silent |

**The trap: CPU work on an event loop.** A single 100ms synchronous computation in a Node.js handler blocks all other requests for 100ms. The pattern: offload CPU work to a worker thread (Node.js `worker_threads`) or a separate process. Profile with `--prof` before assuming your handler is CPU-bound.

```javascript
// blocking the event loop: DON'T
app.get('/compute', (req, res) => {
  const result = heavyComputation(req.query.n);  // blocks for 200ms
  res.json({ result });
});

// correct: offload to worker
const { Worker, isMainThread, workerData, parentPort } = require('worker_threads');
app.get('/compute', (req, res) => {
  const worker = new Worker('./compute-worker.js', { workerData: { n: req.query.n } });
  worker.on('message', result => res.json({ result }));
  worker.on('error', err => res.status(500).json({ error: err.message }));
});
```

---

## Locks & races

A **race condition** is when two concurrent operations read-modify-write shared state, and the final state depends on their interleaving. Classic example:

```python
# two threads, shared counter = 0
# thread A: read(0) → add 1 → write(1)
# thread B: read(0) → add 1 → write(1)   ← read before A wrote
# result: counter = 1 (should be 2)
```

**Mutex (mutual exclusion lock):** one holder at a time. In Python: `threading.Lock()`. In Java: `synchronized` or `ReentrantLock`. In Go: `sync.Mutex`.

**RWMutex (reader-writer lock):** many simultaneous readers, one exclusive writer. Read-heavy data structures (config, routing tables) benefit significantly — reads don't block each other.

**Optimistic locking** (DB-level): don't lock; instead include a `version` column. On update:
```sql
UPDATE orders
SET status = 'shipped', version = version + 1
WHERE id = $1 AND version = $2;
-- if rows_affected == 0: concurrent update detected, retry
```
Works well when conflicts are rare. Falls apart under high contention (many retries, wasted work).

**Pessimistic locking** (DB-level): `SELECT ... FOR UPDATE`. Acquires a row lock immediately. Correct but serializes concurrent access. Use for operations where conflict probability is high or where you can't afford retries (financial debit).

**Deadlock:** two threads each hold a lock the other needs.

```
Thread A: holds Lock 1, waiting for Lock 2
Thread B: holds Lock 2, waiting for Lock 1
→ deadlock
```

Prevention: always acquire locks in the same global order. Detection: Java thread dumps show `BLOCKED` + which lock is being waited on. In databases, the engine detects and aborts one transaction — ensure you handle the error and retry.

---

## Connection pooling

Opening a TCP connection + TLS handshake + database authentication takes 5–50ms. For a service handling 1000 req/s with each request making one DB call, creating a new connection per request would spend more time on handshakes than actual queries. A connection pool amortizes this cost.

**Key pool parameters:**

| Parameter | Meaning | Bad default |
|-----------|---------|-------------|
| `min` / `minIdle` | Connections kept open when idle | Too high = wasted DB connections; too low = cold-start latency |
| `max` / `maxSize` | Maximum open connections | Exceeding DB's `max_connections` will cause errors across all pools |
| `idleTimeout` | Close connection if idle for this long | Too short = cold-start; too long = holding DB resources |
| `connectionTimeout` / `acquireTimeout` | Max time to wait for a connection from the pool | Too low = spurious failures under burst; too high = cascading delay |
| `maxLifetime` | Force-close and replace connections after this age | Prevents using connections past DB-side idle timeout or SSL cert rotation |

**Pool sizing rule.** For a thread-per-request model: each thread that makes a DB call while a request is in-flight needs a connection. A common mistake is setting pool size = max_threads. The correct formula:

```
pool_size = T_service / T_db_per_request
```

Where `T_service` = time to serve one request, `T_db_per_request` = time spent blocked on the DB per request. If a request takes 100ms and spends 20ms waiting on the DB, you need `pool_size = concurrency * 0.2`. HikariCP's documentation has a worked example showing why a 10-connection pool is often optimal for a server with 100 threads.

**Pool exhaustion symptom.** Requests pile up waiting for a connection; latency spikes across the board even for requests that don't need the DB. The fix: check what's holding connections open (`pg_stat_activity` in Postgres), look for long-running transactions, and set `connectionTimeout` so the service fails fast rather than queuing indefinitely.

```sql
-- Postgres: see what's holding your pool
SELECT pid, state, wait_event_type, wait_event, query_start, query
FROM pg_stat_activity
WHERE datname = 'mydb'
ORDER BY query_start;
```

---

## Rate limiting — token bucket

The token bucket algorithm:
- A bucket holds up to `capacity` tokens
- Tokens are added at rate `r` tokens/second
- Each request consumes 1 token; if the bucket is empty, the request is rejected or queued

```
capacity=10, rate=5/s

t=0s:  bucket=[10 tokens]  request arrives → accept, bucket=[9]
t=0s:  burst of 9 more requests → bucket=[0]
t=0.2s: 1 token added → bucket=[1]  next request → accept
t=0.4s: bucket=[2] ...
```

This allows short bursts up to `capacity` while enforcing `rate` sustained throughput. Contrast with a **leaky bucket** (fixed output rate, variable input, fixed queue) — leaky bucket smooths traffic but rejects bursts; token bucket passes bursts.

**Redis-backed token bucket (atomic Lua, no race conditions):**

```lua
-- keys: [bucket_key]  args: [rate, capacity, now_ms, requested]
local tokens_key = KEYS[1]
local last_refill_key = KEYS[1] .. ":ts"

local rate = tonumber(ARGV[1])
local capacity = tonumber(ARGV[2])
local now = tonumber(ARGV[3])
local requested = tonumber(ARGV[4])

local last_refill = tonumber(redis.call("GET", last_refill_key)) or now
local current_tokens = tonumber(redis.call("GET", tokens_key)) or capacity

local elapsed = (now - last_refill) / 1000.0
local new_tokens = math.min(capacity, current_tokens + elapsed * rate)

if new_tokens >= requested then
    redis.call("SET", tokens_key, new_tokens - requested, "PX", 60000)
    redis.call("SET", last_refill_key, now, "PX", 60000)
    return 1
else
    redis.call("SET", tokens_key, new_tokens, "PX", 60000)
    redis.call("SET", last_refill_key, now, "PX", 60000)
    return 0
end
```

Sliding window counter (simpler, no burst): use Redis INCR + EXPIRE keyed on `user_id:minute_bucket`. Works for "100 requests per minute" where you don't care about bursting within the minute.

---

## Retries + backoff + jitter

Retrying on transient failures is correct. Retrying immediately in a tight loop is how you take down a struggling dependency.

**Exponential backoff:**

```python
import time, random

def call_with_retry(fn, max_attempts=5, base_delay=0.1, max_delay=30.0):
    for attempt in range(max_attempts):
        try:
            return fn()
        except TransientError as e:
            if attempt == max_attempts - 1:
                raise
            delay = min(base_delay * (2 ** attempt), max_delay)
            # full jitter: spread retries across [0, delay]
            time.sleep(random.uniform(0, delay))
```

**Full jitter** (`sleep(random(0, delay))`) is almost always better than no jitter, especially under correlated failures where many clients retry simultaneously. Without jitter, every client that failed at the same time retries at the same time — the "thundering herd" / retry storm.

**Which errors to retry:**
- Retry: `503 Service Unavailable`, `429 Too Many Requests`, `ECONNRESET`, `ETIMEDOUT`
- Never retry without idempotency: `POST /orders` — creates a new order each time
- Retry safely: `GET`, `PUT` (idempotent by definition), or any operation with an idempotency key

**Deadline propagation.** Instead of `max_retries`, prefer a deadline: a timestamp by which the entire operation must complete, propagated from the entry point. Retries check the deadline before sleeping:

```python
import time

def call_with_deadline(fn, deadline, base_delay=0.1):
    attempt = 0
    while True:
        remaining = deadline - time.time()
        if remaining <= 0:
            raise DeadlineExceeded()
        try:
            return fn()
        except TransientError:
            delay = min(base_delay * (2 ** attempt), remaining / 2)
            time.sleep(random.uniform(0, delay))
            attempt += 1
```

---

## Circuit breakers

A circuit breaker wraps calls to an external dependency. When failures exceed a threshold, the breaker "opens" and subsequent calls fail immediately without hitting the downstream.

```
CLOSED (normal): requests pass through, failure rate tracked
   → if failure_rate > threshold for window → OPEN

OPEN (tripped): all requests fail-fast (no downstream calls)
   → after reset_timeout → HALF-OPEN

HALF-OPEN (probing): one request let through as probe
   → if succeeds → CLOSED
   → if fails → OPEN (reset timer)
```

**Key parameters:**
- `failureRateThreshold`: e.g., 50% failures in the last 10 calls
- `waitDurationInOpenState`: how long to stay open before probing (e.g., 30s)
- `slidingWindowSize`: number of calls (or time window) for rate calculation
- `minimumNumberOfCalls`: don't open on 1/1 failures at startup

**Python with pybreaker:**

```python
import pybreaker

db_breaker = pybreaker.CircuitBreaker(
    fail_max=5,
    reset_timeout=30,
    listeners=[pybreaker.CircuitBreakerListener()],
)

@db_breaker
def query_user(user_id):
    return db.execute("SELECT * FROM users WHERE id = %s", (user_id,))
```

When the breaker is open, calls raise `pybreaker.CircuitBreakerError` immediately — you catch it and return a cached/degraded response.

---

## Timeouts & bulkheads

**Timeouts at every layer.** A missing timeout converts a slow dependency into an indefinitely-blocked thread (or coroutine). Set timeouts at:
- DNS resolution (often ignored, can hang for 30s)
- TCP connect
- TLS handshake
- HTTP request (separate connect + read timeouts in most clients)
- DB query execution

```python
import httpx

async with httpx.AsyncClient(
    timeout=httpx.Timeout(connect=1.0, read=5.0, write=2.0, pool=1.0)
) as client:
    response = await client.get("https://internal-service/data")
```

Propagate deadlines: if your service must respond in 500ms, and you call two dependencies, set each dependency's timeout to < 500ms minus your processing overhead. A common mistake: each layer adds its own `timeout=30s`, making the total possible wait 90s on a 3-hop call chain.

**Bulkheads.** Isolate resource pools per downstream so one slow dependency can't exhaust the pool for all requests:

```
Without bulkhead:
  payment-svc thread pool [20 threads]
    ↓ all calls go here: 15 threads blocked on slow inventory-svc
    ↓ only 5 threads left for fast auth-svc calls
    → auth calls start queuing even though auth-svc is healthy

With bulkheads:
  payment-svc
    inventory thread pool [8 threads] → inventory-svc
    auth thread pool      [8 threads] → auth-svc
    core thread pool      [4 threads] → internal work
    → inventory slowness cannot starve auth calls
```

In Java/Spring: `ThreadPoolBulkhead` in Resilience4j. In Python/Node: maintain separate asyncio semaphores per downstream.

---

## Idempotency keys

Idempotency keys allow a client to safely retry a non-idempotent operation (e.g., `POST /payments`). The server caches the response for a given key and returns it on repeat calls.

**Protocol:**
1. Client generates a UUID v4 idempotency key before the first attempt.
2. Client sends the key in the request header (`Idempotency-Key: <uuid>`).
3. Server checks the cache; if a response exists for this key, return it immediately.
4. Server processes the request, stores `(key → status_code + response_body)` in Redis with a TTL (e.g., 24h).
5. On retry, step 3 returns the cached response.

**Handling concurrent requests with the same key:**

```python
IDEMPOTENCY_TTL = 86400  # 24h in seconds

async def handle_payment(request):
    idem_key = request.headers.get("Idempotency-Key")
    if not idem_key:
        return 400, {"error": "Idempotency-Key required"}

    lock_key = f"idem:lock:{idem_key}"
    result_key = f"idem:result:{idem_key}"

    # fast path: result cached
    cached = await redis.get(result_key)
    if cached:
        return json.loads(cached)

    # acquire lock to prevent concurrent processing of same key
    acquired = await redis.set(lock_key, "1", nx=True, ex=30)
    if not acquired:
        return 409, {"error": "Request in progress"}

    try:
        result = await process_payment(request.body)
        await redis.set(result_key, json.dumps(result), ex=IDEMPOTENCY_TTL)
        return result
    finally:
        await redis.delete(lock_key)
```

---

## Debugging Concurrency & Reliability

### Thread exhaustion

**Symptom:** all endpoints slow or timing out; new requests queue; logs show `Could not acquire a connection from the pool`; thread pool metrics show 100% utilization.

**Cause → Fix:**

| Pattern | Cause | Fix |
|---------|-------|-----|
| All threads WAITING on one resource | Pool exhaustion (DB, downstream) | Add bulkhead; fix the downstream; reduce query time |
| Threads in BLOCKED state | Lock contention | Profile with thread dump; reduce lock scope; use CAS or lock-free structures |
| Threads in TIMED_WAITING | Retrying too aggressively | Add backoff; add circuit breaker to fail-fast |
| Thread count growing without bound | Thread leak (Executor not shut down, goroutine not closing) | Trace thread creation; use `defer` / try-finally for cleanup |

```bash
# Java: get a thread dump (safe, non-destructive)
jstack <pid> > /tmp/threaddump.txt
grep -c "BLOCKED" /tmp/threaddump.txt       # number of blocked threads
grep -A 5 "BLOCKED" /tmp/threaddump.txt     # what are they waiting for

# Python: get a traceback of all threads
import faulthandler; faulthandler.dump_traceback()

# Node.js: check event loop lag (> 50ms = something blocking the loop)
const { monitorEventLoopDelay } = require('perf_hooks');
const h = monitorEventLoopDelay({ resolution: 10 });
h.enable();
setInterval(() => console.log('event loop lag p99:', h.percentile(99)), 1000);
```

### Retry storms

**Symptom:** a downstream recovers, but instead of normalizing traffic, the recovered service is immediately overwhelmed again. Metrics show request rate 10× above normal for 30–60s after recovery.

**Cause:** all clients that were retrying on backoff hit the retry condition simultaneously (correlated failure → correlated retry). No jitter was added.

**Fix + verification:**

```bash
# check your service's outbound retry rate in logs
grep "retry attempt" app.log | awk '{print $1}' | sort | uniq -c | sort -rn | head

# if you see bursts of identical timestamps, add jitter
# verify jitter is working: retry timestamps should be spread over several seconds
grep "retry attempt 2" app.log | awk '{print $2}' | sort | head -20
```

Mitigation: add full jitter if you haven't. Add circuit breaker so that during the downstream outage, clients fail fast (no retries) and the backlog drains rather than accumulates.

### Deadlocks

**Symptom:** two threads or two DB transactions block forever; timeouts eventually fire; `pg_locks` shows two transactions each waiting for the other.

```bash
# Postgres: find deadlocking transactions
SELECT pid, state, wait_event, pg_blocking_pids(pid) AS blocked_by, query
FROM pg_stat_activity
WHERE cardinality(pg_blocking_pids(pid)) > 0;

# Java: thread dump shows circular BLOCKED chain
jstack <pid> | grep -A 20 "Found one Java-level deadlock"
```

**Fix:** enforce a canonical lock ordering. If operation A always locks `orders` then `inventory`, operation B must never lock `inventory` then `orders`. In the DB: use `SELECT ... FOR UPDATE` with a consistent row ordering (`ORDER BY id`). For code: document and enforce the lock hierarchy in code comments, and add a linter rule or test that detects reversed ordering.

> **War story.** We had a Node.js service handling Stripe webhook events and a separate cron job that reconciled payment states. Both used the same Redis-backed idempotency cache but without a lock on the key during processing. A Stripe retry (their policy is to retry webhooks 3× in quick succession on 2xx timeout) hit while our initial handler was mid-flight — before it wrote the cached result. The second handler saw no cached result, started processing, and both handlers charged the customer and sent a confirmation email. The root symptom: a handful of customers contacted support about duplicate charges. The fix was exactly the `SET NX EX` lock pattern above — acquire a lock by idempotency key before checking or setting the cached result. We only found it because the Stripe test dashboard showed identical event IDs in our received-events log twice. After the fix: zero duplicate charges over the next 60 days in canary traffic.

---

## Checkpoint

You're ready when you can, without looking anything up:

1. Explain why a 200ms synchronous computation in a Node.js HTTP handler is a correctness problem, not just a performance problem.
2. Draw the state machine for a circuit breaker from memory, including what triggers each transition.
3. State the three conditions that can cause a retry storm, and which one jitter directly prevents.
4. Size a connection pool for a Java service with 50 threads where each request spends 30ms of its 150ms total time blocked on the DB.
5. Write a token bucket rate limiter check in pseudocode, identifying where the race condition is and how the Redis Lua script eliminates it.
6. Explain the difference between a semaphore bulkhead and a thread-pool bulkhead, and when each is appropriate.
7. Given a thread dump showing 40/50 threads in `BLOCKED` state waiting for `java.sql.Connection`, name the two most likely root causes and the first command you'd run to confirm each.

➡ Next up: **System Design (SDE-2 → SDE-3)** — how the primitives from this course compose into distributed systems: sharding, consistency models, caching tiers, and the back-of-envelope reasoning that separates design-review passes from handwavy diagrams.
