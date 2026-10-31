# Solution: Circuit Breaker State Machine

## Key Implementation Points

The state is not a simple field — it's computed: when the circuit is OPEN, checking whether `recovery_timeout` has elapsed determines if it should expose HALF_OPEN to callers. That logic belongs in the `state` property, not scattered through call sites.

```python
import time
from typing import Callable, Any


class CircuitOpenError(Exception):
    pass


class CircuitBreaker:
    CLOSED    = "CLOSED"
    OPEN      = "OPEN"
    HALF_OPEN = "HALF_OPEN"

    def __init__(self, failure_threshold: int, recovery_timeout: float):
        self.failure_threshold = failure_threshold
        self.recovery_timeout  = recovery_timeout
        self._failure_count    = 0
        self._state            = self.CLOSED
        self._opened_at        = None   # timestamp when circuit opened

    @property
    def state(self) -> str:
        if self._state == self.OPEN:
            if time.monotonic() - self._opened_at >= self.recovery_timeout:
                return self.HALF_OPEN
        return self._state

    def call(self, fn: Callable) -> Any:
        current = self.state
        if current == self.OPEN:
            raise CircuitOpenError("circuit is OPEN — fast-failing")

        try:
            result = fn()
        except Exception:
            self._on_failure()
            raise
        else:
            self._on_success()
            return result

    def _on_failure(self):
        self._failure_count += 1
        if self._state == self.HALF_OPEN or self._failure_count >= self.failure_threshold:
            self._state     = self.OPEN
            self._opened_at = time.monotonic()
            self._failure_count = 0   # reset so the next CLOSED phase starts fresh

    def _on_success(self):
        self._state         = self.CLOSED
        self._failure_count = 0
        self._opened_at     = None
```

## Why `state` Is a Property, Not a Field

The transition from OPEN to HALF_OPEN is **time-driven**, not event-driven. There is no background thread setting a flag. The property computes the effective state on every read: if `_state == OPEN` and the timeout has elapsed, return `HALF_OPEN`. This keeps the implementation single-threaded and straightforward without a timer thread.

## The Half-Open Probe

Only one call is allowed in HALF_OPEN at a time in this implementation. In production (Resilience4j, gobreaker), there is a configurable `permitted_number_of_calls_in_half_open_state`. For this challenge the single-probe model is correct.

## Failure Count Reset After Opening

When the circuit opens (either from CLOSED reaching the threshold, or a failed probe in HALF_OPEN), the failure count resets to zero. This ensures the next CLOSED phase starts with a clean count — a service that just recovered is not one failure away from reopening.
