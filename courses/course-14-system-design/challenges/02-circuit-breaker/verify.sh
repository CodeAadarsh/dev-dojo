#!/usr/bin/env bash
# Verifier for "Circuit Breaker State Machine".
set -uo pipefail

WORK="$HOME/.kube-dojo-work/02-circuit-breaker"
FLAG='KUBE{circuit_breaker_half_open_probe}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ] || fail "work directory missing — run setup.sh first"
[ -f "$WORK/circuit_breaker.py" ] || fail "circuit_breaker.py not found in $WORK"

cd "$WORK"

if [ -f ".venv/bin/pytest" ]; then
    PYTEST=".venv/bin/pytest"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
else
    fail "pytest not found — activate the venv: python3 -m venv .venv && . .venv/bin/activate && pip install pytest"
fi

HIDDEN_DIR="$WORK/.hidden_tests"
mkdir -p "$HIDDEN_DIR"

cat > "$HIDDEN_DIR/__init__.py" << 'PYEOF'
PYEOF

cat > "$HIDDEN_DIR/test_hidden_cb.py" << 'PYEOF'
"""
Hidden circuit-breaker verifier tests.
Checks that fn is not called when OPEN, and that the circuit fully recovers.
"""
import time
import pytest
import sys
import os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from circuit_breaker import CircuitBreaker, CircuitOpenError


def test_fn_not_called_when_open():
    """fn must never be invoked while the circuit is OPEN."""
    call_count = {"n": 0}

    def tracked():
        call_count["n"] += 1
        return "ok"

    cb = CircuitBreaker(failure_threshold=2, recovery_timeout=10)
    for _ in range(2):
        with pytest.raises(Exception):
            cb.call(lambda: (_ for _ in ()).throw(RuntimeError("down")))
    assert cb.state == "OPEN"

    with pytest.raises(CircuitOpenError):
        cb.call(tracked)
    assert call_count["n"] == 0, "fn must not be called when circuit is OPEN"


def test_full_recovery_cycle():
    """CLOSED → OPEN → HALF_OPEN → CLOSED → normal calls succeed."""
    cb = CircuitBreaker(failure_threshold=3, recovery_timeout=0.05)

    for _ in range(3):
        with pytest.raises(RuntimeError):
            cb.call(lambda: (_ for _ in ()).throw(RuntimeError("down")))
    assert cb.state == "OPEN"

    time.sleep(0.1)
    assert cb.state == "HALF_OPEN"

    result = cb.call(lambda: "recovered")
    assert result == "recovered"
    assert cb.state == "CLOSED"

    # after recovery, normal calls succeed without CircuitOpenError
    for _ in range(5):
        r = cb.call(lambda: "ok")
        assert r == "ok"
    assert cb.state == "CLOSED"


def test_failure_count_resets_after_recovery():
    """After recovery, a new set of failures from scratch should re-open at threshold."""
    cb = CircuitBreaker(failure_threshold=3, recovery_timeout=0.05)

    # first trip
    for _ in range(3):
        with pytest.raises(RuntimeError):
            cb.call(lambda: (_ for _ in ()).throw(RuntimeError("down")))
    time.sleep(0.1)
    cb.call(lambda: "probe ok")   # recover
    assert cb.state == "CLOSED"

    # two failures should NOT open (threshold is 3)
    for _ in range(2):
        with pytest.raises(RuntimeError):
            cb.call(lambda: (_ for _ in ()).throw(RuntimeError("transient")))
    assert cb.state == "CLOSED", "Two failures must not reopen a circuit with threshold=3"

    # third failure should open
    with pytest.raises(RuntimeError):
        cb.call(lambda: (_ for _ in ()).throw(RuntimeError("down again")))
    assert cb.state == "OPEN"
PYEOF

if $PYTEST tests/ "$HIDDEN_DIR/" -q 2>&1; then
    echo
    echo "All tests passed. Submit this flag in the platform:"
    echo
    echo "    $FLAG"
else
    fail "test suite has failures — fix your implementation and retry"
fi
