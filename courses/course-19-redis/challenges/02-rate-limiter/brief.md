# Fixed-Window Rate Limiter

You are on-call. A PagerDuty alert fires at 2 am: *"POST /api/ingest — 50 000 req/min from a single client IP. Database CPU at 100%. P99 latency 8 s and climbing."* The RCA is straightforward — no rate limiting on the ingest endpoint. The fix needs to be deployed before the next wave.

The Redis INCR+EXPIRE pattern is the standard immediate solution. No schema migration, no library, no restart — two commands wired into the request path. The deeper lesson is understanding *why* the pattern works, where it fails atomically, and what separates it from the correct Lua-based solution.

## Prerequisites

**Docker must be running.** `setup.sh` starts a `dojo-redis` container on host port **6399** if one is not already present.

## How the pattern works

```
INCR   rate:<user_id>          # atomically increment a per-user counter; returns new count
EXPIRE rate:<user_id> 60 NX    # set 60s TTL only if the key has no TTL yet (NX = "not exists")
```

**Why NX is load-bearing.** Without NX, every request resets the 60-second window clock. A user hitting the endpoint 10 times per second would never be blocked — each EXPIRE pushes the expiry forward and the key never dies. With NX, the TTL is stamped once, on the **first** request of the window (counter = 1). All subsequent EXPIRE calls are no-ops. When the window expires, the key disappears, the next INCR creates it fresh, and EXPIRE NX stamps a new window.

```
Request 1:  INCR -> 1,  EXPIRE 60 NX -> 1 (TTL set)   -> ALLOWED
Request 2:  INCR -> 2,  EXPIRE 60 NX -> 0 (noop)      -> ALLOWED
Request 3:  INCR -> 3,  EXPIRE 60 NX -> 0 (noop)      -> ALLOWED
Request 4:  INCR -> 4,  EXPIRE 60 NX -> 0 (noop)      -> ALLOWED
Request 5:  INCR -> 5,  EXPIRE 60 NX -> 0 (noop)      -> ALLOWED
Request 6:  INCR -> 6,  EXPIRE 60 NX -> 0 (noop)      -> BLOCKED  (count > 5)
Request 7:  INCR -> 7,  EXPIRE 60 NX -> 0 (noop)      -> BLOCKED
... (60s later, key expires, counter resets)
```

## Mission

`setup.sh` scaffolds `~/.kube-dojo-work/02-rate-limiter/rate_limiter.sh`. Implement it so the verifier passes.

**Script contract: `rate_limiter.sh <user_id>`**

| Condition              | stdout output | Exit code |
|------------------------|---------------|-----------|
| Request count ≤ 5      | `ALLOWED`     | 0         |
| Request count > 5      | `BLOCKED`     | 1         |

Rules:
- Limit: **5 requests** per **60-second** window.
- Redis key: `rate:<user_id>` (e.g. `rate:alice`).
- The key **must have a positive TTL** after the first request in a window.
- Use `INCR` and `EXPIRE ... NX`; do not use SETEX or any Lua script for this challenge.

## Verifier contract

The verifier:

1. Deletes any pre-existing `rate:<test-user>` key (clean window).
2. Calls `rate_limiter.sh <test-user>` exactly **7 times** in sequence.
3. Asserts exactly **5 ALLOWED** and **2 BLOCKED** responses (in that order — first 5 allowed, last 2 blocked).
4. Checks `TTL rate:<test-user>` is a positive integer (EXPIRE was applied).

```bash
bash courses/course-19-redis/challenges/02-rate-limiter/setup.sh
# edit ~/.kube-dojo-work/02-rate-limiter/rate_limiter.sh
bash courses/course-19-redis/challenges/02-rate-limiter/verify.sh
```

## Atomicity caveat

`INCR` is a single atomic operation at the Redis server — no race condition on the counter itself. But `INCR` and `EXPIRE NX` are **two separate round trips**. If the process is killed (or the network drops) between them, you get a counter with no TTL that lives forever. Under normal single-threaded bash usage in this lab this will not happen, but in a production Go or Node.js service it is a real issue at high concurrency. The correct atomic fix is a Lua script that calls both in one server-side execution — you will implement exactly that pattern in the Distributed Lock challenge.
