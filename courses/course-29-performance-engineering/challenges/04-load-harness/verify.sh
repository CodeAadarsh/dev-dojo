#!/usr/bin/env bash
# Verifier for "Build a Load Harness".
# Runs a hidden pytest harness against harness.py; prints the flag only when
# all five checks pass.  Exit 0 = solved, 1 = not yet.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/04-load-harness"
FLAG='KUBE{load_harness_concurrency_measured}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ]          || fail "work directory missing — run setup.sh first"
[ -f "$WORK/harness.py" ] || fail "harness.py not found — run setup.sh first"

PYTEST=""
if [ -f "$WORK/.venv/bin/pytest" ]; then
    PYTEST="$WORK/.venv/bin/pytest"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
else
    fail "pytest not found — cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install pytest"
fi

# Write hidden tests to a temp directory so the learner cannot see or pre-load them.
TMPDIR_HIDDEN=$(mktemp -d)
trap 'rm -rf "$TMPDIR_HIDDEN"' EXIT

cp "$WORK/harness.py" "$TMPDIR_HIDDEN/"

cat > "$TMPDIR_HIDDEN/test_hidden.py" << 'PYEOF'
"""
Hidden verifier test suite for 04-load-harness.
Uses its own inline StubServer so the learner cannot game it by modifying stub_server.py.
"""
import sys
import time
import threading

# harness.py was copied into this temp directory by verify.sh
from harness import run_load, HarnessResult


# ── inline stub (tamper-resistant) ───────────────────────────────────────────
class StubServer:
    def __init__(self, latency_ms: float = 10.0):
        self._latency_s = latency_ms / 1000.0
        self._lock = threading.Lock()
        self._current = 0
        self.max_observed_concurrent: int = 0
        self.call_count: int = 0

    def handle(self, payload=None):
        with self._lock:
            self._current += 1
            if self._current > self.max_observed_concurrent:
                self.max_observed_concurrent = self._current
        try:
            time.sleep(self._latency_s)
            return {"ok": True}
        finally:
            with self._lock:
                self._current -= 1
                self.call_count += 1


# ── tests ────────────────────────────────────────────────────────────────────
def test_total_requests():
    """All n_requests calls must complete and be counted."""
    stub = StubServer(latency_ms=5)
    r = run_load(stub.handle, n_requests=100, concurrency=5)
    assert r.total_requests == 100, (
        f"expected total_requests=100, got {r.total_requests}"
    )
    assert stub.call_count == 100, (
        f"stub processed {stub.call_count} calls, expected 100"
    )


def test_concurrency_cap_enforced():
    """In-flight call count must never exceed the concurrency cap."""
    stub = StubServer(latency_ms=15)
    run_load(stub.handle, n_requests=80, concurrency=5)
    assert stub.max_observed_concurrent <= 5, (
        f"concurrency cap violated: max_concurrent={stub.max_observed_concurrent} > 5"
    )


def test_actually_uses_concurrency():
    """Harness must dispatch calls concurrently, not sequentially.
    With latency=60ms and concurrency=10, at least 5 threads must overlap."""
    stub = StubServer(latency_ms=60)
    run_load(stub.handle, n_requests=30, concurrency=10)
    assert stub.max_observed_concurrent >= 5, (
        f"harness looks sequential: peak concurrent = {stub.max_observed_concurrent} "
        f"(expected >= 5 with concurrency=10 and 60ms latency)"
    )


def test_latencies_collected():
    """Every request must contribute a latency entry; p95 must be measurable."""
    stub = StubServer(latency_ms=5)
    r = run_load(stub.handle, n_requests=50, concurrency=5)
    assert len(r.latencies_ms) == 50, (
        f"expected 50 latency entries, got {len(r.latencies_ms)}"
    )
    assert r.p95_ms >= 1.0, (
        f"p95={r.p95_ms:.2f}ms is suspiciously low — are latencies being measured?"
    )


def test_throughput_positive():
    """elapsed_s must be tracked and throughput_rps > 0."""
    stub = StubServer(latency_ms=5)
    r = run_load(stub.handle, n_requests=20, concurrency=5)
    assert r.throughput_rps > 0, (
        "throughput_rps must be > 0 — is elapsed_s being recorded?"
    )
PYEOF

cd "$TMPDIR_HIDDEN"

if $PYTEST test_hidden.py -v 2>&1; then
    echo
    echo "All checks passed. Submit this flag in the platform:"
    echo
    echo "    $FLAG"
else
    fail "one or more checks failed — fix harness.py and retry"
fi
