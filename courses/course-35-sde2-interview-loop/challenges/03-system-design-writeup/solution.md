# Solution — System Design: Rate Limiter

The flag is `KUBE{rate_limiter_design_tradeoffs}`.

## Full Reference Design

Below is a complete design that passes the verifier. Your doc doesn't need to match word-for-word — this is a reference for *depth and structure*.

---

## Requirements

### Functional
- Accept or reject an incoming request based on a configurable limit and window per key.
- Support three key types: user ID, IP address, API key.
- Per-key configuration: `(key_type, key_value, limit, window_seconds)`.
- Return the remaining quota and the reset timestamp on every call.

### Non-Functional
- Peak throughput: 50 000 req/s.
- Latency overhead: < 5 ms p99 added to the request path.
- Availability: 99.9% (< 8.7 h downtime/year).
- Accuracy: at most 0.1% over-limit acceptance under normal operation.

### Out of Scope
- Billing or quota purchase flows.
- Admin UI for managing limits.
- Per-endpoint analytics and reporting.

---

## Capacity Estimate

**Throughput:**
```
50 000 req/s × 1 Redis operation/req = 50 000 Redis ops/s
A Redis single-node handles ~100 000–200 000 simple ops/s — one node is sufficient
at this scale, but we need replication for availability.
```

**Memory (token bucket, one entry per key):**
```
State per key: count (4 bytes) + last_refill (8 bytes) + key (avg 32 bytes) = ~44 bytes
10M keys × 44 bytes = 440 MB
Redis overhead (pointer, expiry): ~2× = ~880 MB
One Redis instance with 2 GB RAM is sufficient. Use 4 GB to leave headroom.
```

**Latency budget:**
```
5 ms p99 budget.
LAN RTT to Redis: ~0.5 ms median.
Lua script execution: ~0.1 ms.
Total per-call overhead: ~0.6–1 ms median, well within 5 ms p99 for same-AZ Redis.
Cross-AZ Redis would add 2–5 ms — avoid for the hot path.
```

---

## API Design

Internal service API (called by the API gateway or a sidecar, not exposed externally):

```
check_and_consume(
    key: str,               # e.g. "user:12345", "ip:1.2.3.4", "apikey:abc123"
    limit: int,             # max requests allowed in the window
    window_seconds: int     # rolling window length
) -> RateLimitResult

RateLimitResult:
    allowed: bool           # true if the request is within quota
    remaining: int          # tokens left after this request (0 if denied)
    reset_at: int           # Unix timestamp when the window resets / refills
    retry_after_ms: int     # 0 if allowed; ms until retry is safe if denied
```

---

## Data Model

**Algorithm choice: Token Bucket** (see trade-offs section).

Redis Hash per key:

```
HSET rl:{key}  count {N}  last_refill {unix_ts_float}
EXPIRE rl:{key} {window_seconds * 2}
```

- `count`: current token count (float for fractional refill).
- `last_refill`: Unix timestamp of the last refill calculation.
- TTL: 2× window so idle keys expire automatically.

The entire read-refill-write cycle runs in a single Redis Lua script to be atomic:

```lua
local key = KEYS[1]
local limit = tonumber(ARGV[1])
local window = tonumber(ARGV[2])
local now = tonumber(ARGV[3])  -- passed in from the caller; avoids TIME command in scripts

local data = redis.call("HMGET", key, "count", "last_refill")
local count = tonumber(data[1]) or limit
local last_refill = tonumber(data[2]) or now

-- Refill tokens based on elapsed time
local elapsed = now - last_refill
local refill = (elapsed / window) * limit
count = math.min(limit, count + refill)
last_refill = now

local allowed = 0
if count >= 1 then
    count = count - 1
    allowed = 1
end

redis.call("HSET", key, "count", count, "last_refill", last_refill)
redis.call("EXPIRE", key, window * 2)
return {allowed, math.floor(count), math.ceil(last_refill + window)}
```

The Lua script runs atomically on the Redis server — no race condition.

---

## High-Level Design

```
Client Request
      |
      v
API Gateway (Nginx / Envoy)
      |
      v
Rate Limiter Sidecar (same pod / same host)
  - Reads limit config from config service (cached locally, refreshed every 30s)
  - Calls Redis via Lua script
  - On Redis timeout/failure: falls back to local in-memory token bucket (fail-open with degraded accuracy)
      |
      v
Redis Cluster (3 primary + 3 replica shards, same AZ as API gateway)
      |
     [allowed] ---> Backend Service
     [denied]  ---> 429 Too Many Requests
```

**Placement:** Sidecar on every API gateway node. No extra network hop to a standalone service. The sidecar handles local config cache and the Redis call.

**Availability:** Redis Sentinel or Cluster (Redis Cluster recommended at this scale) gives automatic failover in < 30s, achieving 99.9%+ at the Redis layer.

**Failure mode (fail-open):** If the Redis call exceeds 2 ms or returns an error, the sidecar falls back to a local in-memory counter for up to 5 seconds. This allows a burst of up to `limit × sidecar_count` extra requests during a Redis outage — acceptable for non-payment APIs. For the payment API specifically, we use fail-closed (deny on Redis failure) because the cost of over-limit transactions exceeds the cost of a 5-second denial.

---

## Trade-offs and Bottlenecks

**Token bucket versus sliding window log:**

Token bucket stores only two numbers per key (O(1) space). A sliding window log stores every request timestamp in the window (O(limit) space per key). At 10M keys × 100 req/min limit, a sliding window log would require ~10B sorted-set members — around 80 GB of Redis memory. Token bucket fits in < 1 GB. Trade-off: token bucket permits a burst of up to `limit` requests at the start of each window; sliding window log provides smooth rate enforcement. For a payment API where burst risk is real, we add a burst cap parameter to the token bucket.

**Fixed window versus token bucket:**

Fixed window (`INCR` + `EXPIRE`) is simpler but has a boundary spike: a user can make `2×limit` requests in a short span straddling a window boundary. Token bucket eliminates this. Trade-off: token bucket requires a Lua script (slightly more complex) instead of a single `INCR`. The correctness gain is worth it for the payment path.

**Fail-open versus fail-closed:**

Fail-open (allow traffic when Redis is down) maximizes availability but risks burst traffic reaching backends during an outage — acceptable for low-value APIs. Fail-closed (deny traffic when Redis is down) protects backends at the cost of 429s during a Redis incident. For the payment API: fail-closed. For the search API: fail-open. The choice must be per-API and documented explicitly.

**Bottleneck at 10× scale (500K req/s):**

A single Redis node saturates at ~200K ops/s. At 500K req/s we'd need 3–4 Redis shards. Redis Cluster with consistent hashing on the key partitions naturally scales horizontally. The sidecar's connection pool becomes the next bottleneck — each sidecar instance needs a pool of 10–20 connections to each shard. At 500K req/s across 100 gateway nodes, that's 5K req/s per node — well within a single Redis connection's throughput.

---

## What the Interviewer Is Looking For

A 4/5 design has the right components. A 5/5 design explains the *why* at each decision and identifies what breaks next. The two sections that level-differentiate most are Trade-offs (algorithm choice reasoning) and the failure mode discussion (fail-open vs fail-closed with a concrete argument).
