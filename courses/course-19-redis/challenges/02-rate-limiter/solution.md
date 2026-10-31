# Solution — Fixed-Window Rate Limiter

The flag is `KUBE{rate_limiter_incr_expire}`.

## Implementation

```bash
#!/usr/bin/env bash
set -euo pipefail

USER_ID="${1:?Usage: rate_limiter.sh <user_id>}"
LIMIT=5
WINDOW=60
KEY="rate:$USER_ID"

COUNT=$(docker exec dojo-redis redis-cli INCR "$KEY")
docker exec dojo-redis redis-cli EXPIRE "$KEY" $WINDOW NX >/dev/null

if [ "$COUNT" -le "$LIMIT" ]; then
  echo "ALLOWED"
  exit 0
else
  echo "BLOCKED"
  exit 1
fi
```

Replace the stub in `~/.kube-dojo-work/02-rate-limiter/rate_limiter.sh` with this body. Then run the verifier.

## Why this works — line by line

**INCR** is a server-side atomic read-modify-write. The Redis docs guarantee it returns the value *after* the increment, with no other client able to observe an intermediate value. Two concurrent INCR calls on the same key always return consecutive integers, never the same number.

**EXPIRE "$KEY" $WINDOW NX** uses the NX (Not eXists) option introduced in Redis 7.0. It sets the TTL *only if the key currently has no expiry*. The sequence for a fresh window:

```
t=0  INCR -> 1   (key created with no TTL)
t=0  EXPIRE 60 NX -> 1  (TTL set, expires at t=60)
t=1  INCR -> 2
t=1  EXPIRE 60 NX -> 0  (TTL already set, this is a noop)
...
t=59 INCR -> N
t=60 key expires, counter gone
t=60 INCR -> 1   (new key, new window)
t=60 EXPIRE 60 NX -> 1  (TTL set again)
```

Without NX, every request calls `EXPIRE 60` which pushes the window forward 60 seconds. A user sending one request per second would never hit the window boundary — the key lives forever and the counter only grows.

## The atomicity gap

The two commands (`INCR` + `EXPIRE NX`) are separate round trips. The sequence is:

```
[client] INCR  -> [Redis: counter = 1]
[client crash here]
[Redis: counter = 1, no TTL, key lives forever]
```

In a single-process bash script this is extremely unlikely. In a high-concurrency Node.js service handling thousands of requests per second, this is a real failure mode. The correct atomic implementation uses a Lua script:

```lua
-- atomic_rate_limiter.lua
local count = redis.call("INCR", KEYS[1])
if count == 1 then
  redis.call("EXPIRE", KEYS[1], tonumber(ARGV[1]))
end
return count
```

```bash
COUNT=$(docker exec dojo-redis redis-cli EVAL \
  "local c=redis.call('INCR',KEYS[1]);if c==1 then redis.call('EXPIRE',KEYS[1],tonumber(ARGV[1])) end;return c" \
  1 "$KEY" $WINDOW)
```

The Lua script runs atomically in Redis's single-threaded command loop — no other command executes between the INCR and the EXPIRE check. You implement this full atomic pattern in the Distributed Lock challenge.

## Fixed window vs token bucket

**Fixed window** (this challenge): the limit resets at discrete clock boundaries (e.g. the window starts on the first request and expires 60s later). A user can burst `LIMIT` at the end of window N and `LIMIT` at the start of window N+1 — `2 * LIMIT` requests in a span of 2 seconds at the boundary. Acceptable for most API rate limits.

**Sliding window log**: store each request timestamp in a sorted set, discard entries older than the window on each request, count remaining entries. Exact count, no boundary burst, but O(requests-per-window) memory per user.

**Token bucket**: refill at a constant rate up to a capacity. Allows short bursts up to capacity, then steady-state at the refill rate. Requires two values (tokens remaining + last refill time) and an atomic Lua script. Most accurate model of sustained vs burst traffic.

For the ingest-endpoint incident, fixed window is the right emergency fix: two redis-cli calls, no external library, deployed in minutes.

## Checking rate limiter state manually

```bash
# See current counter for a user
docker exec dojo-redis redis-cli GET rate:alice

# See remaining TTL (seconds until window resets)
docker exec dojo-redis redis-cli TTL rate:alice

# Manually reset a user (useful in testing)
docker exec dojo-redis redis-cli DEL rate:alice

# See all rate limiter keys
docker exec dojo-redis redis-cli KEYS "rate:*"
```
