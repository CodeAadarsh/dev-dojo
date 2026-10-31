#!/usr/bin/env bash
# Plants the circuit-breaker starter project into the work directory.
# Idempotent — re-running overwrites skeleton files.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/02-circuit-breaker"
mkdir -p "$WORK/tests"

# ── circuit_breaker.py skeleton ───────────────────────────────────────────────
cat > "$WORK/circuit_breaker.py" << 'PYEOF'
# circuit_breaker.py — implement the CircuitBreaker class
import time
from typing import Callable, Any


class CircuitOpenError(Exception):
    """Raised when a call is attempted while the circuit is OPEN."""


class CircuitBreaker:
    """
    Three-state circuit breaker: CLOSED → OPEN → HALF_OPEN → CLOSED.

    Args:
        failure_threshold: number of consecutive failures to trigger OPEN
        recovery_timeout:  seconds to wait in OPEN before probing (HALF_OPEN)
    """

    CLOSED    = "CLOSED"
    OPEN      = "OPEN"
    HALF_OPEN = "HALF_OPEN"

    def __init__(self, failure_threshold: int, recovery_timeout: float):
        self.failure_threshold = failure_threshold
        self.recovery_timeout  = recovery_timeout
        # implement: set initial state and counters
        raise NotImplementedError("implement __init__")

    @property
    def state(self) -> str:
        """Return current state string. Must account for timeout expiry."""
        raise NotImplementedError("implement state property")

    def call(self, fn: Callable) -> Any:
        """
        Execute fn() according to the current state.

        CLOSED / HALF_OPEN:
          - fn() raises  → record failure; update state; re-raise the original exception
          - fn() returns → record success; update state; return the value

        OPEN:
          - raise CircuitOpenError immediately; do NOT call fn()
        """
        raise NotImplementedError("implement call")
PYEOF

# ── tests/test_circuit_breaker.py harness ────────────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

cat > "$WORK/tests/test_circuit_breaker.py" << 'PYEOF'
import time
import pytest
import sys
import os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from circuit_breaker import CircuitBreaker, CircuitOpenError


def boom():
    raise RuntimeError("downstream is down")


def ok():
    return "ok"


def test_starts_closed():
    cb = CircuitBreaker(failure_threshold=3, recovery_timeout=0.1)
    assert cb.state == "CLOSED"


def test_failure_threshold_opens_circuit():
    cb = CircuitBreaker(failure_threshold=3, recovery_timeout=0.1)
    for _ in range(3):
        with pytest.raises(RuntimeError):
            cb.call(boom)
    assert cb.state == "OPEN"


def test_open_raises_circuit_open_error():
    cb = CircuitBreaker(failure_threshold=2, recovery_timeout=10)
    for _ in range(2):
        with pytest.raises(RuntimeError):
            cb.call(boom)
    with pytest.raises(CircuitOpenError):
        cb.call(ok)


def test_recovery_to_half_open():
    cb = CircuitBreaker(failure_threshold=2, recovery_timeout=0.05)
    for _ in range(2):
        with pytest.raises(RuntimeError):
            cb.call(boom)
    assert cb.state == "OPEN"
    time.sleep(0.1)
    assert cb.state == "HALF_OPEN"


def test_successful_probe_closes_circuit():
    cb = CircuitBreaker(failure_threshold=2, recovery_timeout=0.05)
    for _ in range(2):
        with pytest.raises(RuntimeError):
            cb.call(boom)
    time.sleep(0.1)
    result = cb.call(ok)
    assert result == "ok"
    assert cb.state == "CLOSED"


def test_failed_probe_reopens_circuit():
    cb = CircuitBreaker(failure_threshold=2, recovery_timeout=0.05)
    for _ in range(2):
        with pytest.raises(RuntimeError):
            cb.call(boom)
    time.sleep(0.1)
    assert cb.state == "HALF_OPEN"
    with pytest.raises(RuntimeError):
        cb.call(boom)
    assert cb.state == "OPEN"
PYEOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : implement CircuitBreaker in circuit_breaker.py so all"
echo "                 6 visible tests pass. The verifier adds checks for"
echo "                 fn-not-called-when-open and post-recovery behaviour."
echo
echo "Prerequisites  :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate"
echo "  pip install pytest"
echo
echo "Run tests      : cd $WORK && .venv/bin/pytest tests/ -v"
echo "Verify + flag  : bash courses/course-14-system-design/challenges/02-circuit-breaker/verify.sh"
