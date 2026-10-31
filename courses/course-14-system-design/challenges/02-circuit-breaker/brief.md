# Circuit Breaker State Machine

The recommendations service your checkout flow depends on started returning 504s at 11pm on a Friday. Within 90 seconds, every checkout thread on every instance was waiting 30 seconds for the recommendations service to time out, the checkout thread pool filled completely, and the API gateway marked the checkout service unhealthy. Total checkout outage caused by a **non-critical** dependency.

The post-mortem action item assigned to you: implement a circuit breaker around every non-critical downstream call.

## Mission

Implement `circuit_breaker.py` in `~/.kube-dojo-work/02-circuit-breaker/` with a `CircuitBreaker` class that correctly models the three states:

```
CLOSED → (failure_count >= threshold) → OPEN
OPEN   → (timeout elapsed) → HALF_OPEN
HALF_OPEN → (probe succeeds) → CLOSED
HALF_OPEN → (probe fails)   → OPEN
```

The class interface (pre-defined in the skeleton):

```python
class CircuitBreaker:
    def __init__(self, failure_threshold: int, recovery_timeout: float):
        ...

    def call(self, fn: Callable) -> Any:
        """
        If CLOSED or HALF_OPEN: call fn().
          - fn() raises → record failure; transition state if needed; re-raise.
          - fn() succeeds → record success; transition state if needed; return result.
        If OPEN: raise CircuitOpenError without calling fn().
        """

    @property
    def state(self) -> str:
        """Returns 'CLOSED', 'OPEN', or 'HALF_OPEN'."""
```

The verifier checks:

1. `failure_threshold` consecutive failures transition CLOSED → OPEN.
2. Calls while OPEN raise `CircuitOpenError` immediately (fn is never called).
3. After `recovery_timeout` seconds the state moves to HALF_OPEN.
4. A successful probe in HALF_OPEN resets the circuit to CLOSED (failure count reset).
5. A failed probe in HALF_OPEN sends the circuit back to OPEN (timeout restarts).
6. After recovery, subsequent calls succeed normally (CLOSED behavior).

## Why this matters

Without the HALF_OPEN probe step, a circuit that opened on a transient failure would either stay open forever (service never recovers) or flip straight back to CLOSED and immediately re-fill the thread pool if the dependency is still sick. The probe is the key: one test call, fail-fast on failure, reopen for full traffic only on success.
