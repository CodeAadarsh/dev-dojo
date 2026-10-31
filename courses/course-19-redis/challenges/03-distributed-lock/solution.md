# Solution — Distributed Lock with Lua Release

The flag is `KUBE{distributed_lock_nx_lua}`.

## Implementation

### acquire.sh

```bash
#!/usr/bin/env bash
set -euo pipefail

KEY="${1:?Usage: acquire.sh <key> <token> <ttl_ms>}"
TOKEN="${2:?acquire.sh: token required}"
TTL="${3:?acquire.sh: ttl_ms required}"

RESULT=$(docker exec dojo-redis redis-cli SET "$KEY" "$TOKEN" NX PX "$TTL")

if [ "$RESULT" = "OK" ]; then
  echo "ACQUIRED"
  exit 0
else
  echo "FAILED"
  exit 1
fi
```

### release.sh

```bash
#!/usr/bin/env bash
set -euo pipefail

KEY="${1:?Usage: release.sh <key> <token>}"
TOKEN="${2:?release.sh: token required}"

RESULT=$(docker exec dojo-redis redis-cli EVAL \
  "if redis.call('GET',KEYS[1])==ARGV[1] then return redis.call('DEL',KEYS[1]) else return 0 end" \
  1 "$KEY" "$TOKEN")

if [ "$RESULT" = "1" ]; then
  echo "RELEASED"
  exit 0
else
  echo "NOT_OWNER"
  exit 1
fi
```

Replace the stubs in `~/.kube-dojo-work/03-distributed-lock/` with these bodies, then run the verifier.

## Why SET NX PX, not SETNX + EXPIRE

The legacy approach was two commands:

```bash
redis-cli SETNX lock:job my-token   # set if not exists
redis-cli EXPIRE lock:job 30000     # set TTL in ms
```

This has the same atomicity gap as the INCR+EXPIRE pattern in the rate limiter: a crash between SETNX and EXPIRE leaves a key with no TTL that locks the system forever (deadlock). `SET key value NX PX ttl` is a single atomic command introduced in Redis 2.6.12 — it either sets the key with the TTL in one operation or does nothing. There is no window for a partial write.

## The Lua release script — internals

```lua
if redis.call("GET", KEYS[1]) == ARGV[1] then
  return redis.call("DEL", KEYS[1])
else
  return 0
end
```

The script runs inside Redis's single-threaded command dispatcher. No other command can execute between the GET and the conditional DEL — the comparison and the delete are one atomic unit. This is the only correct way to implement "release only if I own it" in Redis.

The EVAL signature: `EVAL script numkeys key [key ...] arg [arg ...]`
- `1` = numkeys (one key follows)
- `KEYS[1]` = the lock key
- `ARGV[1]` = the caller's token

Lua arrays in Redis are 1-indexed, which is why `KEYS[1]` and `ARGV[1]`, not `KEYS[0]`.

Return value: `1` (integer) if DEL ran, `0` if the token did not match.

## The failure mode this prevents

```
t=0    Worker A: SET lock:job token-A NX PX 5000   -> OK (TTL = 5s)
t=4    Worker A: stalls (slow GC, blocked I/O)
t=5    TTL expires. lock:job is gone.
t=5    Worker B: SET lock:job token-B NX PX 5000   -> OK (lock re-acquired)
t=4.1  Worker A: resumes; calls DEL lock:job       -> deletes token-B's lock!
t=4.1  Worker B now has no lock, but thinks it does.
t=4.1  Worker C acquires the same lock.
       Workers B and C both run concurrently. Data corruption.
```

With the Lua release:

```
t=4.1  Worker A: EVAL ... lock:job token-A
       Redis GET lock:job -> "token-B"
       "token-B" != "token-A"  -> return 0
       Worker A prints NOT_OWNER, does NOT delete the key.
       Worker B's lock survives.
```

## Token generation in production

The token must be unique per lock-holder per acquisition attempt. Common choices:

| Token format | Uniqueness guarantee |
|---|---|
| `$(uuidgen)` | UUID v4, probabilistically unique |
| `$$-$(date +%s%N)` | PID + nanosecond timestamp |
| `$(hostname)-$(uuidgen)` | Host + UUID (useful in logs) |

In Go: `uuid.New().String()` from `github.com/google/uuid`. In Node.js: `crypto.randomUUID()`.

Never use a static string (`"my-job"`) as the token — if two workers both use `"my-job"` as their token, Worker A's expired lock can be released by Worker B because the tokens match.

## Heartbeat pattern for long-running jobs

If your job takes longer than the TTL, implement a heartbeat:

```bash
# In a background loop while the job runs:
while kill -0 "$JOB_PID" 2>/dev/null; do
  # Extend TTL only if we still own the lock
  docker exec dojo-redis redis-cli EVAL \
    "if redis.call('GET',KEYS[1])==ARGV[1] then return redis.call('PEXPIRE',KEYS[1],tonumber(ARGV[2])) else return 0 end" \
    1 "$LOCK_KEY" "$MY_TOKEN" 30000
  sleep 10
done
```

If the heartbeat fails to extend (returns 0), the lock expired and another holder took over — your job should detect this and abort rather than continue writing concurrently.

## RedLock — distributed locks across multiple Redis nodes

The single-node pattern here is correct for a single Redis instance. For a fully distributed setup (multiple independent Redis masters, no replication), the RedLock algorithm requires acquiring the lock on a majority (N/2 + 1) of nodes within a short time window. The Redlock spec is at https://redis.io/docs/manual/patterns/distributed-locks/ — study it before implementing in a multi-region setup.
