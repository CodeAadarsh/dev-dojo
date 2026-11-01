#!/usr/bin/env bash
# Plants the "Build a Load Harness" starter project into the work directory.
# Idempotent — re-running overwrites skeleton files but does not delete .venv.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/04-load-harness"
mkdir -p "$WORK/tests"

# ── harness.py skeleton ──────────────────────────────────────────────────────
cat > "$WORK/harness.py" << 'PYEOF'
"""
harness.py — open-model load harness skeleton.

Implement run_load(target_fn, n_requests, concurrency) using Python threading
(threading.Semaphore or concurrent.futures.ThreadPoolExecutor both work).

Do NOT modify stub_server.py.  Only this file should change.
"""
import time
import threading
from dataclasses import dataclass, field
from typing import Callable, List


@dataclass
class HarnessResult:
    total_requests: int = 0
    latencies_ms: List[float] = field(default_factory=list)
    elapsed_s: float = 0.0

    @property
    def p95_ms(self) -> float:
        """95th-percentile latency in milliseconds."""
        if not self.latencies_ms:
            return 0.0
        s = sorted(self.latencies_ms)
        idx = max(0, int(0.95 * len(s)) - 1)
        return s[idx]

    @property
    def throughput_rps(self) -> float:
        """Completed requests per second over the whole run."""
        if self.elapsed_s <= 0:
            return 0.0
        return self.total_requests / self.elapsed_s


def run_load(target_fn: Callable, n_requests: int, concurrency: int) -> HarnessResult:
    """
    Send exactly n_requests calls to target_fn(), keeping at most `concurrency`
    calls in flight at any moment.  Collect per-call wall-clock latency (ms).
    Return a populated HarnessResult.

    Constraints verified by verify.sh:
      - result.total_requests == n_requests
      - max concurrent in-flight calls to target_fn <= concurrency
      - result.latencies_ms has exactly n_requests entries
      - result.p95_ms > 0
      - result.throughput_rps > 0
    """
    raise NotImplementedError("implement run_load")
PYEOF

# ── stub_server.py ────────────────────────────────────────────────────────────
cat > "$WORK/stub_server.py" << 'PYEOF'
"""
stub_server.py — deterministic target stub used in visible tests.

StubServer.handle() sleeps for `latency_ms` milliseconds (simulating network
or compute latency) and records the peak number of concurrent callers.

Do NOT modify this file.  verify.sh uses its own inline copy of the stub so
changes here do not affect the hidden tests.
"""
import time
import threading


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
PYEOF

# ── tests/__init__.py ─────────────────────────────────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

# ── tests/test_visible.py ─────────────────────────────────────────────────────
cat > "$WORK/tests/test_visible.py" << 'PYEOF'
"""Visible smoke tests — verify the API contract.  Run: pytest tests/ -v"""
import sys
import os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from harness import run_load, HarnessResult
from stub_server import StubServer


def test_returns_harness_result():
    stub = StubServer(latency_ms=1)
    result = run_load(stub.handle, n_requests=10, concurrency=2)
    assert isinstance(result, HarnessResult)


def test_request_count_smoke():
    stub = StubServer(latency_ms=1)
    result = run_load(stub.handle, n_requests=20, concurrency=5)
    assert result.total_requests == 20, (
        f"expected total_requests=20, got {result.total_requests}"
    )
PYEOF

echo
echo "Work directory  : $WORK"
echo
echo "Task            : implement run_load() in $WORK/harness.py"
echo "                  so that all five verifier checks pass."
echo
echo "Prerequisites   :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate"
echo "  pip install pytest"
echo
echo "Run smoke tests : cd $WORK && .venv/bin/pytest tests/ -v"
echo "Verify + flag   : bash courses/course-29-performance-engineering/challenges/04-load-harness/verify.sh"
