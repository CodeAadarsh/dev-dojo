# Solution — Pick the Right Rate-Limiting Algorithm

The flag is `KUBE{token_bucket_burst_tolerant}`.

**Token bucket** is the only algorithm that satisfies all three constraints simultaneously. Here is the full analysis.

---

## The tradeoff matrix

| Algorithm | Distributed? | Burst-tolerant? | O(1) memory/key? |
|---|:---:|:---:|:---:|
| Fixed window | ✓ | ✗ (boundary burst) | ✓ |
| Sliding log | ✓ | ✓ | ✗ (O(n) per key) |
| Leaky bucket | ✓ | ✗ (smooths, doesn't accumulate) | ✓ |
| **Token bucket** | ✓ | ✓ | ✓ |

---

## Why each loser fails

### Fixed window — fails burst-tolerance

State: one counter + one window-start timestamp. O(1) per key.

The flaw is the window boundary. If your window is 00:00–01:00 and a client sends
100 requests at 00:59 and 100 at 01:01, they get 200 requests in 2 seconds while
your stated limit is 100/min. Any client that learns (or guesses) your window boundary
can reliably double the limit with no complex tooling. This is the "window burst problem."

It also has the inverse of burst tolerance: accumulated quiet time buys you nothing.
A client that sent zero requests for the last 10 minutes cannot "use up" that quiet
time in a brief spike — the current window counter still resets at the window boundary.

### Sliding log — fails memory constraint

State: a sorted set of request timestamps for the past window. O(n) per key.

This is the most *accurate* algorithm — it never allows the window-boundary double-burst,
and it accounts for every timestamp precisely. The problem is memory. At 100 req/s per
key, each key's log holds up to 6,000 timestamps (for a 60s window). At 10M active
keys, that is ~60 billion timestamp entries. At 8 bytes per int64 timestamp, that is
480 GB of Redis memory before any serialisation overhead. Not viable.

Mitigation strategies exist (time-bucketed sliding window, Redis ZRANGEBYSCORE + TTL)
but they either degrade accuracy toward fixed-window or add per-key memory that still
scales with rate, not toward O(1).

### Leaky bucket — fails burst-tolerance

State: queue length + last-drain timestamp. O(1) per key (amortised, assuming bounded queue).

The leaky bucket *accepts* bursts into a queue but *processes* them at a constant rate.
An incoming spike doesn't get rejected — it gets *delayed*. A client that's been idle
for 5 seconds fires 300 requests: they all enter the queue, and the queue drains at
100/s, so the last request gets a 2-second artificial latency. That's not burst
tolerance — it's burst *deferral with latency cost*.

For a flash sale or a mobile client recovering from network loss, this means: the burst
is "handled" in the sense that nothing is dropped, but the user sees an anomalous 3-4s
spike in latency. Worse, if the queue is bounded (it must be for the O(1) guarantee),
excess requests *are* dropped — and the drop point is the queue length limit, not the
stated rate, which makes capacity planning harder.

### Token bucket — wins all three

State: `{token_count: float, last_refill_ts: int64}` — 12–16 bytes per key. **O(1).**

Mechanics: tokens accumulate at `rate` tokens/second, capped at `capacity` (the burst
ceiling). Each request consumes one token; if the bucket is empty, the request is
rejected (or queued, depending on policy). You can also use fractional tokens for
sub-second precision.

**Burst-tolerant:** if a key has been idle for 5 seconds and its rate is 100/s with a
capacity of 300 tokens, the bucket is at 300. The client fires 300 requests
immediately — they all pass. Subsequent requests are throttled at 100/s. This is
exactly what the constraint requires: accumulated quiet time converts to burst capacity.

**Distributed:** the implementation is a two-step Redis Lua script (atomic):
```
local tokens = tonumber(redis.call('hget', KEYS[1], 'tokens'))
local last    = tonumber(redis.call('hget', KEYS[1], 'last_refill'))
local now     = tonumber(ARGV[1])  -- current time in seconds (float)
local rate    = tonumber(ARGV[2])
local cap     = tonumber(ARGV[3])

tokens = math.min(cap, tokens + (now - last) * rate)
redis.call('hset', KEYS[1], 'last_refill', now)

if tokens >= 1.0 then
    redis.call('hset', KEYS[1], 'tokens', tokens - 1.0)
    return 1  -- allowed
else
    redis.call('hset', KEYS[1], 'tokens', tokens)
    return 0  -- denied
end
```
The Lua script runs atomically — no TOCTOU race between pods. Redis replication handles HA.

**O(1) memory:** at 10M keys × 16 bytes = 160 MB. That fits in a single Redis instance
with headroom for key overhead.

---

## Real-world deployments

| System | Algorithm | Notes |
|--------|-----------|-------|
| AWS API Gateway | Token bucket | Per-route, per-stage; burst configured separately from steady-state rate |
| Stripe | Token bucket (with Redis Lua) | Published in their blog circa 2016; basis for most SaaS rate limiters since |
| GitHub REST API | Sliding window (hybrid) | Uses a sliding window approximation because accuracy matters for their SLA; they can afford the Redis memory |
| Nginx `limit_req` | Leaky bucket | Fixed-rate smoothing for HTTP — fine for ingress, wrong if clients legitimately spike |

---

## Common mistakes

| Mistake | Consequence |
|---------|-------------|
| Using fixed window to avoid Redis complexity | Double-burst at window boundary; clients reverse-engineer it in minutes |
| Using sliding log without capping log size | Redis OOM at scale; not caught until production load |
| Using leaky bucket and calling it burst-tolerant | It absorbs bursts into a queue — high tail latency, not genuine acceptance |
| Setting token-bucket capacity = rate (1 second of tokens) | Effectively kills burst tolerance; capacity should be 3–10× the per-second rate |
| Not using a Lua script (doing GET then SET in two round trips) | Race condition: two pods simultaneously read 0.5 tokens, both write -0.5, both allow the request |

---

> **War story.** A payments platform we consulted for had a fixed-window limiter with a 60-second window. A penetration tester discovered the window reset at :00 of each minute. They built a script: fire 100 requests at 59.9 seconds, then another 100 at 00.1 seconds — 200 requests in 200 ms. Their brute-force credential-stuffing attack bypassed the stated 100/min limit entirely. Switching to token bucket with a Redis Lua implementation fixed it and also let them set burst capacity to 150 tokens (1.5 seconds of genuine headroom) for mobile clients on flaky connections, without opening the boundary exploit.

---

## Checkpoint

You understand the algorithms when you can, without notes:

1. Explain the fixed-window boundary attack with exact timestamps.
2. Derive the memory usage of sliding log at 10M keys × 100 req/s × 60s window.
3. Explain why leaky bucket delays, but does not accept, bursts.
4. Write the token-bucket state structure (two fields) and explain why the Lua script must be atomic.
5. State which bucket parameter sets the burst size and which sets the steady-state rate.
