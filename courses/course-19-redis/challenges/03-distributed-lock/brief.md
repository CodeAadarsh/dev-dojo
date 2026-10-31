# Distributed Lock with Lua Release

Your team runs a batch job that reprocesses billing data. The job takes 8 minutes and must never run concurrently — two instances writing the same records cause billing discrepancies. You deploy two workers for redundancy, add a flag in Postgres to track "job running", and go home. Two weeks later a network partition means both workers read the flag as `false` simultaneously and both start. Duplicate charges hit customers.

The fix is a **distributed lock** with a correctness guarantee that a database flag cannot provide: atomic acquisition, automatic expiry on worker death, and — critically — a safe release that cannot free a lock held by a different holder.

## Prerequisites

**Docker must be running.** `setup.sh` starts a `dojo-redis` container on host port **6399** if one is not already present.

## The pattern

### Acquire

```bash
SET lock:<resource> <token> NX PX <ttl_ms>
```

- `NX` — only set if the key does **not** exist (atomic test-and-set).
- `PX <ttl_ms>` — auto-expire if the holder crashes before releasing (prevents deadlock).
- `<token>` — a unique value per holder (UUID, PID, hostname+timestamp). This is what makes safe release possible.
- Returns `OK` on success, nil/empty on failure (key already held).

### Release — why you must use Lua

The naive release is `DEL lock:<resource>`. This is **wrong**:

```
Worker A acquires lock, TTL = 5s.
Worker A stalls (GC pause, slow query) for 6s.
TTL expires. Lock is free.
Worker B acquires the same lock with its own token.
Worker A resumes, calls DEL. It just deleted Worker B's lock.
Worker B now has two concurrent holders.
```

The correct release is an atomic compare-and-delete: *delete the key only if its current value matches my token*. Redis provides no native command for this, but it provides **Lua scripting** — a Lua script runs atomically on the server, with no other commands interleaved:

```lua
if redis.call("GET", KEYS[1]) == ARGV[1] then
  return redis.call("DEL", KEYS[1])
else
  return 0
end
```

Returns `1` (integer) if the lock was released, `0` if the token did not match.

Execute via:

```bash
docker exec dojo-redis redis-cli EVAL \
  "if redis.call('GET',KEYS[1])==ARGV[1] then return redis.call('DEL',KEYS[1]) else return 0 end" \
  1 lock:<resource> <token>
```

## Mission

`setup.sh` scaffolds two scripts in `~/.kube-dojo-work/03-distributed-lock/`:

| Script | Contract |
|--------|----------|
| `acquire.sh <key> <token> <ttl_ms>` | Exits 0 and prints `ACQUIRED` if lock obtained; exits 1 and prints `FAILED` if already held |
| `release.sh <key> <token>` | Exits 0 and prints `RELEASED` if token matched and key deleted; exits 1 and prints `NOT_OWNER` if token mismatch |

## Verifier contract

The verifier runs this exact sequence:

1. `DEL lock:dojo` (clean state).
2. `acquire.sh lock:dojo token-alice 30000` → must exit **0** (lock free, acquire succeeds).
3. Checks `EXISTS lock:dojo` = 1 and `GET lock:dojo` = `token-alice`.
4. `acquire.sh lock:dojo token-bob 30000` → must exit **1** (lock held, acquire must fail).
5. Checks `GET lock:dojo` is still `token-alice` (bob's attempt must not overwrite).
6. `release.sh lock:dojo wrong-token` → must exit **1** (token mismatch, must not delete).
7. Checks `EXISTS lock:dojo` = 1 (lock must survive the wrong-token release attempt).
8. `release.sh lock:dojo token-alice` → must exit **0** (correct token, lock released).
9. Checks `EXISTS lock:dojo` = 0 (key must be gone).

```bash
bash courses/course-19-redis/challenges/03-distributed-lock/setup.sh
# implement acquire.sh and release.sh in ~/.kube-dojo-work/03-distributed-lock/
bash courses/course-19-redis/challenges/03-distributed-lock/verify.sh
```

## Why TTL prevents deadlock

Without a TTL, a worker that crashes mid-job leaves the lock key in Redis forever. Every subsequent worker reads the key as held and refuses to start. The job never runs again until someone manually deletes the key — which no one will remember to do at 3 am during an incident. The `PX` option on SET means the lock auto-releases after `ttl_ms` milliseconds even if the holder never calls `release.sh`. The tradeoff: TTL must be longer than the job's worst-case runtime, or a slow-but-alive worker finds its lock expired and races with a new holder. In practice: set TTL to 10x the expected runtime, and implement a heartbeat that extends the TTL while the job is alive.
