#!/usr/bin/env bash
# Plants the "Automated GameDay Runner" Python skeleton into the work directory.
# Idempotent: re-running overwrites source files but leaves .venv intact.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/06-automated-gameday"
mkdir -p "$WORK/tests"

# ── system.py ────────────────────────────────────────────────────────────────
cat > "$WORK/system.py" << 'PYEOF'
# system.py — deterministic mock system for automated GameDay experiments.
# Uses a seeded RNG so every run is reproducible.
import random
from typing import List, Tuple


class MockSystem:
    """
    Models a system with an SLO, a fault toggle, and an event audit log.

    Attributes
    ----------
    healthy_success_rate : float  — success rate under normal conditions
    fault_success_rate   : float  — success rate while fault is active
    events               : list   — ordered log of (event_type, label) tuples
    """

    def __init__(
        self,
        healthy_success_rate: float = 0.999,
        fault_success_rate: float = 0.40,
    ):
        self._healthy_rate = healthy_success_rate
        self._fault_rate = fault_success_rate
        self._fault_active = False
        self._rng = random.Random(42)
        self.events: List[Tuple[str, str]] = []

    def request(self) -> dict:
        """
        Make a single request.
        Returns {'success': bool, 'latency_ms': float}.
        """
        rate = self._fault_rate if self._fault_active else self._healthy_rate
        success = self._rng.random() < rate
        latency = self._rng.uniform(1.0, 10.0) if success else self._rng.uniform(50.0, 200.0)
        return {'success': success, 'latency_ms': latency}

    def inject_fault(self, label: str = 'unnamed') -> None:
        """Activate the fault and record the event."""
        self._fault_active = True
        self.events.append(('fault_injected', label))

    def rollback(self, label: str = 'unnamed') -> None:
        """Deactivate the fault and record the rollback event."""
        self._fault_active = False
        self.events.append(('rollback', label))

    def measure_slo(self, n: int = 500) -> float:
        """Measure current success rate over n requests."""
        results = [self.request() for _ in range(n)]
        return sum(r['success'] for r in results) / len(results)

    @property
    def fault_active(self) -> bool:
        return self._fault_active
PYEOF

# ── gameday.py — implementation stub ─────────────────────────────────────────
cat > "$WORK/gameday.py" << 'PYEOF'
# gameday.py
# Implement run_gameday below.
# Read system.py first — especially inject_fault(), rollback(), and measure_slo().
from typing import Optional


class ExperimentReport:
    """
    Structured record of a single chaos experiment run.
    All fields are set by run_gameday.
    """

    def __init__(self):
        self.steady_state_before: Optional[float] = None
        self.steady_state_after: Optional[float] = None
        self.fault_period_slo: Optional[float] = None
        self.aborted: bool = False
        self.abort_reason: Optional[str] = None

    def to_dict(self) -> dict:
        return {
            'steady_state_before': self.steady_state_before,
            'steady_state_after': self.steady_state_after,
            'fault_period_slo': self.fault_period_slo,
            'aborted': self.aborted,
            'abort_reason': self.abort_reason,
        }


def run_gameday(
    system,
    slo_threshold: float = 0.95,
    n_baseline: int = 500,
    n_monitor: int = 200,
    experiment_label: str = 'gameday-1',
) -> ExperimentReport:
    """
    Automated experiment runner. Lifecycle (in order):

    1. Record steady-state BEFORE: system.measure_slo(n_baseline) → report.steady_state_before
    2. Inject fault: system.inject_fault(experiment_label)
    3. Monitor SLO during fault — take 3 samples of n_monitor calls each:
         a. If any sample < slo_threshold:
              - system.rollback(experiment_label)
              - report.aborted = True
              - report.abort_reason = 'slo_breach'
              - report.fault_period_slo = min(samples so far)
              - return report immediately
    4. No breach: system.rollback(experiment_label)
    5. Record steady-state AFTER: system.measure_slo(n_baseline) → report.steady_state_after
       (only when NOT aborted)
    6. report.fault_period_slo = min(all 3 fault-period samples)
    7. return report

    Notes
    -----
    - steady_state_after is None when aborted (do not measure it).
    - fault_period_slo uses min() — worst case, not average.
    - system.fault_active must be False when this function returns (rollback always happens).
    """
    raise NotImplementedError
PYEOF

# ── tests/__init__.py ────────────────────────────────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

# ── tests/test_visible.py ────────────────────────────────────────────────────
cat > "$WORK/tests/test_visible.py" << 'PYEOF'
import sys
import os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from system import MockSystem
from gameday import run_gameday, ExperimentReport


def test_experiment_report_fields():
    report = ExperimentReport()
    d = report.to_dict()
    for key in ('steady_state_before', 'steady_state_after', 'fault_period_slo', 'aborted', 'abort_reason'):
        assert key in d, f"ExperimentReport.to_dict() is missing key: {key}"


def test_run_gameday_returns_report_instance():
    sys_ = MockSystem(healthy_success_rate=0.999, fault_success_rate=0.98)
    report = run_gameday(sys_, slo_threshold=0.95, n_baseline=100, n_monitor=50)
    assert isinstance(report, ExperimentReport), "run_gameday must return an ExperimentReport"


def test_run_gameday_sets_steady_state_before():
    sys_ = MockSystem(healthy_success_rate=0.999, fault_success_rate=0.98)
    report = run_gameday(sys_, slo_threshold=0.95, n_baseline=100, n_monitor=50)
    assert report.steady_state_before is not None, "steady_state_before must be set"
    assert 0.0 <= report.steady_state_before <= 1.0


def test_run_gameday_fault_always_removed():
    sys_ = MockSystem(healthy_success_rate=0.999, fault_success_rate=0.40)
    run_gameday(sys_, slo_threshold=0.95, n_baseline=100, n_monitor=50)
    assert sys_.fault_active is False, "fault must be deactivated when run_gameday returns"
PYEOF

echo
echo "Work directory : $WORK"
echo
echo "Files planted  :"
echo "  system.py             — mock system (fault injection, SLO measurement, event log)"
echo "  gameday.py            — your implementation target (run_gameday + ExperimentReport)"
echo "  tests/test_visible.py — 4 visible tests to develop against"
echo
echo "Get started    :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate"
echo "  pip install pytest"
echo "  pytest tests/test_visible.py -v"
echo
echo "Verify + flag  :"
echo "  bash courses/course-28-chaos-engineering/challenges/06-automated-gameday/verify.sh"
