#!/usr/bin/env bash
# Plants the "Steady-State Hypothesis" Python skeleton into the work directory.
# Idempotent: re-running overwrites source files but leaves .venv intact.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/05-steady-state-hypothesis"
mkdir -p "$WORK/tests"

# ── simulator.py ────────────────────────────────────────────────────────────
cat > "$WORK/simulator.py" << 'PYEOF'
# simulator.py — deterministic service simulator for chaos experiments.
# Uses a seeded RNG so results are reproducible across runs.
import random


class ServiceSimulator:
    """
    Models a service with a configurable success rate and a toggleable fault.

    Attributes
    ----------
    base_success_rate : float  — success rate under normal conditions (0–1)
    fault_success_rate : float — success rate while fault is active (0–1)
    fault_active : bool        — current fault state; toggled by inject_fault / remove_fault
    """

    def __init__(
        self,
        base_success_rate: float = 0.999,
        fault_active: bool = False,
        fault_success_rate: float = 0.50,
    ):
        self.base_success_rate = base_success_rate
        self.fault_active = fault_active
        self.fault_success_rate = fault_success_rate
        self._rng = random.Random(42)

    def call(self) -> bool:
        """Make a single service call. Returns True for success, False for failure."""
        rate = self.fault_success_rate if self.fault_active else self.base_success_rate
        return self._rng.random() < rate

    def inject_fault(self) -> None:
        """Activate the fault, dropping success rate to fault_success_rate."""
        self.fault_active = True

    def remove_fault(self) -> None:
        """Deactivate the fault, restoring the base success rate."""
        self.fault_active = False

    def reset(self) -> None:
        """Reset the RNG to its initial seed (repeatable experiments)."""
        self._rng = random.Random(42)

    def measure_success_rate(self, n_calls: int = 1000) -> float:
        """Run n_calls and return the fraction that succeeded."""
        return sum(self.call() for _ in range(n_calls)) / n_calls
PYEOF

# ── steady_state.py — implementation stub ───────────────────────────────────
cat > "$WORK/steady_state.py" << 'PYEOF'
# steady_state.py
# Implement the two functions below.
# Read simulator.py first — especially ServiceSimulator.measure_success_rate().


class SteadyStateError(Exception):
    """
    Raised when the measured SLI is below the threshold.

    Attributes
    ----------
    measured_rate : float  — the rate that was measured
    threshold     : float  — the threshold it failed to meet
    """

    def __init__(self, measured_rate: float, threshold: float, message: str = ""):
        self.measured_rate = measured_rate
        self.threshold = threshold
        super().__init__(
            message or f"SLI {measured_rate:.4f} < threshold {threshold:.4f}"
        )


def check_steady_state(simulator, sli_threshold: float = 0.99, n_samples: int = 1000) -> float:
    """
    Measure the simulator's success rate over n_samples calls.

    Parameters
    ----------
    simulator    : ServiceSimulator instance
    sli_threshold: minimum acceptable success rate
    n_samples    : number of calls to measure over

    Returns
    -------
    float — the measured success rate

    Raises
    ------
    SteadyStateError — if measured_rate < sli_threshold, carrying the rate and threshold
    """
    raise NotImplementedError


def run_chaos_experiment(
    simulator,
    fault_duration_calls: int = 1000,
    sli_threshold: float = 0.99,
    n_samples: int = 1000,
) -> dict:
    """
    Run a full chaos experiment:

    1. Verify pre-condition (n_samples calls via check_steady_state).
       If it raises SteadyStateError: set result['aborted']=True and return early.
       Do NOT inject the fault when the baseline is already broken.
    2. Inject fault via simulator.inject_fault().
    3. Measure under fault: fault_duration_calls via simulator.measure_success_rate().
    4. Always remove fault via simulator.remove_fault() (use a try/finally).
    5. Return a dict:
         {
           'pre_rate':        float | None,  # baseline success rate
           'during_rate':     float | None,  # rate under fault (None if aborted)
           'hypothesis_held': bool,          # True if during_rate >= sli_threshold
           'aborted':         bool,          # True if pre-condition failed
         }

    Note: 'hypothesis_held' False is a valid, *useful* result — you found a weakness.
    """
    raise NotImplementedError
PYEOF

# ── tests/__init__.py ────────────────────────────────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

# ── tests/test_visible.py — visible development harness ─────────────────────
cat > "$WORK/tests/test_visible.py" << 'PYEOF'
import sys
import os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from simulator import ServiceSimulator
from steady_state import check_steady_state, SteadyStateError, run_chaos_experiment


def test_check_steady_state_healthy_system():
    sim = ServiceSimulator(base_success_rate=0.999)
    rate = check_steady_state(sim, sli_threshold=0.99, n_samples=500)
    assert rate >= 0.99, f"healthy system should pass 99% threshold, got {rate:.4f}"


def test_check_steady_state_raises_when_degraded():
    sim = ServiceSimulator(base_success_rate=0.60)
    try:
        check_steady_state(sim, sli_threshold=0.99, n_samples=500)
        assert False, "should have raised SteadyStateError on a 60% success rate"
    except SteadyStateError as e:
        assert e.measured_rate < 0.99, "measured_rate should be below threshold"
        assert e.threshold == 0.99


def test_run_experiment_structure():
    sim = ServiceSimulator(base_success_rate=0.999, fault_success_rate=0.80)
    result = run_chaos_experiment(sim, fault_duration_calls=500, sli_threshold=0.99, n_samples=500)
    assert isinstance(result, dict), "run_chaos_experiment must return a dict"
    for key in ('pre_rate', 'during_rate', 'hypothesis_held', 'aborted'):
        assert key in result, f"result dict missing key: {key}"


def test_run_experiment_aborts_on_bad_baseline():
    # Base rate 50% fails the 99% threshold — experiment should abort without injecting fault
    sim = ServiceSimulator(base_success_rate=0.50, fault_success_rate=0.10)
    result = run_chaos_experiment(sim, sli_threshold=0.99, n_samples=500)
    assert result['aborted'] is True, "should abort when baseline fails threshold"
    # fault was never injected, so fault_active should still be False
    assert sim.fault_active is False, "fault must not be injected when pre-condition fails"
PYEOF

echo
echo "Work directory : $WORK"
echo
echo "Files planted  :"
echo "  simulator.py          — deterministic service simulator"
echo "  steady_state.py       — your implementation target (2 functions)"
echo "  tests/test_visible.py — visible development harness (4 tests)"
echo
echo "Get started    :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate"
echo "  pip install pytest"
echo "  pytest tests/test_visible.py -v"
echo
echo "Verify + flag  :"
echo "  bash courses/course-28-chaos-engineering/challenges/05-steady-state-hypothesis/verify.sh"
