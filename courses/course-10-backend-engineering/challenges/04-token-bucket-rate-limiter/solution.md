# Solution — Token Bucket Rate Limiter

The flag is `KUBE{token_bucket_rate_limiter}`.

## Correct implementation

```python
import threading
import time


class TokenBucketLimiter:
    def __init__(self, capacity: int, refill_rate: float) -> None:
        self.capacity = capacity
        self.refill_rate = refill_rate
        self._tokens = float(capacity)       # start full
        self._last_refill = time.monotonic()
        self._lock = threading.Lock()

    def allow(self) -> bool:
        with self._lock:
            now = time.monotonic()
            elapsed = now - self._last_refill
            # add tokens proportional to elapsed time, capped at capacity
            self._tokens = min(float(self.capacity), self._tokens + elapsed * self.refill_rate)
            self._last_refill = now

            if self._tokens >= 1.0:
                self._tokens -= 1.0
                return True
            return False
```

## Why each piece matters

**`time.monotonic()` not `time.time()`**  
Wall-clock time can jump backwards (NTP correction, `settimeofday`, leap second smearing). A backward jump would give a negative `elapsed`, subtracting tokens and creating artificial scarcity. `monotonic()` is guaranteed non-decreasing for the lifetime of the process.

**Float tokens**  
The bucket refills continuously, not in discrete ticks. `elapsed * refill_rate` yields a fractional number of tokens on every call. Without floats you would need a background goroutine or ticker to add whole tokens, which complicates shutdown and testing.

**`min(capacity, ...)`**  
Without the cap, a 10-minute idle window banks 600 seconds × refill_rate tokens — a legitimate burst ceiling would be completely bypassed. The cap bounds the maximum instantaneous burst to `capacity`.

**`threading.Lock`**  
The read-modify-write on `_tokens` and `_last_refill` is not atomic in Python. Two threads can both observe `_tokens >= 1`, both subtract 1.0, and both return `True` — granting one extra request. This is a TOCTOU (time-of-check/time-of-use) race. The lock serialises all calls through the critical section.

## Edge cases to harden for production

- **Zero refill_rate**: bucket never refills; useful for a burst-only window (e.g., 100 requests at startup, never more).
- **Float precision drift**: after billions of calls `_tokens` can accumulate floating-point error; re-clamp to `[0, capacity]` periodically or use `Decimal`.
- **Per-key limiters**: one `TokenBucketLimiter` instance per user/IP key stored in a `dict`; wrap with a per-key lock or use a `defaultdict` with a factory.

## Why in-memory is not enough at scale

A single-instance token bucket works for one process. With 10 replicas each has its own bucket: effective rate = `10 × refill_rate`. Solutions:

- **Redis atomic Lua script** — `EVAL` a script that does the read-modify-write atomically inside Redis; single writer, all replicas share the bucket.
- **Envoy/Istio + central ratelimit service** — rate limiting moved out of the app into the service mesh sidecar; app code stays clean.
- **NGINX Ingress** `nginx.ingress.kubernetes.io/limit-rps` — shared counters via `lua_shared_dict` in NGINX worker processes (single-node); still only one replica of the Ingress controller owns the state.
