#!/usr/bin/env bash
# Verifier for "Steady-State Hypothesis".
# Writes a hidden pytest suite into the work directory, runs it, and prints
# the flag only when all tests pass. Exit 0 = solved, 1 = not yet.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/05-steady-state-hypothesis"
FLAG='KUBE{steady_state_hypothesis_guards_sli}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ]              || fail "work directory missing — run setup.sh first"
[ -f "$WORK/simulator.py" ] || fail "simulator.py missing — run setup.sh first"
[ -f "$WORK/steady_state.py" ] || fail "steady_state.py missing — run setup.sh first"

cd "$WORK"

# ── write the hidden test suite ──────────────────────────────────────────────
cat > "$WORK/tests/test_hidden.py" << 'PYEOF'
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from simulator import ServiceSimulator
from steady_state import check_steady_state, SteadyStateError, run_chaos_experiment


# ── check_steady_state ───────────────────────────────────────────────────────

def test_check_passes_under_tolerable_fault():
    # fault already active, 95% success rate, threshold 90% — should pass
    sim = ServiceSimulator(base_success_rate=0.999, fault_active=True, fault_success_rate=0.95)
    rate = check_steady_state(sim, sli_threshold=0.90, n_samples=2000)
    assert rate >= 0.90, f"95% success rate should pass 90% threshold, got {rate:.4f}"


def test_check_trips_under_intolerable_fault():
    # fault already active, 50% success rate, threshold 90% — must raise
    sim = ServiceSimulator(base_success_rate=0.999, fault_active=True, fault_success_rate=0.50)
    try:
        check_steady_state(sim, sli_threshold=0.90, n_samples=2000)
        assert False, "50% success rate should raise SteadyStateError against 90% threshold"
    except SteadyStateError as e:
        assert e.measured_rate < 0.90, f"measured_rate should be below threshold, got {e.measured_rate:.4f}"
        assert e.threshold == 0.90


def test_check_returns_measured_rate():
    sim = ServiceSimulator(base_success_rate=0.999)
    rate = check_steady_state(sim, sli_threshold=0.95, n_samples=1000)
    assert isinstance(rate, float), "check_steady_state must return a float"
    assert 0.0 <= rate <= 1.0, f"measured rate must be in [0,1], got {rate}"


# ── run_chaos_experiment ─────────────────────────────────────────────────────

def test_experiment_aborts_on_pre_condition_failure():
    # base rate 50% — well below 99% threshold — abort without injecting
    sim = ServiceSimulator(base_success_rate=0.50, fault_success_rate=0.10)
    result = run_chaos_experiment(sim, fault_duration_calls=1000, sli_threshold=0.99, n_samples=1000)
    assert result['aborted'] is True, "must abort when baseline fails threshold"
    assert result['pre_rate'] is not None, "pre_rate must be set even when aborting"
    assert result['pre_rate'] < 0.99, f"pre_rate should reflect the bad baseline, got {result['pre_rate']:.4f}"
    assert sim.fault_active is False, "fault must not be injected when pre-condition fails"


def test_experiment_holds_hypothesis_under_mild_fault():
    # healthy baseline, mild fault (95% success) vs 90% threshold — hypothesis holds
    sim = ServiceSimulator(base_success_rate=0.999, fault_active=False, fault_success_rate=0.95)
    result = run_chaos_experiment(sim, fault_duration_calls=1000, sli_threshold=0.90, n_samples=2000)
    assert result['aborted'] is False
    assert result['hypothesis_held'] is True, \
        f"95% fault success rate should hold 90% threshold, during_rate={result.get('during_rate')}"
    assert result['during_rate'] is not None
    assert result['during_rate'] >= 0.90


def test_experiment_fails_hypothesis_under_severe_fault():
    # healthy baseline, severe fault (50% success) vs 90% threshold — hypothesis violated
    sim = ServiceSimulator(base_success_rate=0.999, fault_active=False, fault_success_rate=0.50)
    result = run_chaos_experiment(sim, fault_duration_calls=1000, sli_threshold=0.90, n_samples=2000)
    assert result['aborted'] is False
    assert result['hypothesis_held'] is False, \
        f"50% fault success rate should violate 90% threshold, during_rate={result.get('during_rate')}"
    assert result['during_rate'] < 0.90


def test_experiment_always_removes_fault():
    # fault must be removed regardless of experiment outcome
    sim = ServiceSimulator(base_success_rate=0.999, fault_success_rate=0.50)
    run_chaos_experiment(sim, fault_duration_calls=500, sli_threshold=0.90, n_samples=500)
    assert sim.fault_active is False, "fault must always be removed after the experiment"


def test_experiment_pre_rate_reflects_baseline():
    sim = ServiceSimulator(base_success_rate=0.999)
    result = run_chaos_experiment(sim, fault_duration_calls=500, sli_threshold=0.95, n_samples=1000)
    assert result['pre_rate'] is not None
    assert result['pre_rate'] >= 0.95, \
        f"pre_rate should reflect 99.9% baseline, got {result['pre_rate']:.4f}"
PYEOF

# ── locate pytest ────────────────────────────────────────────────────────────
if [ -f "$WORK/.venv/bin/pytest" ]; then
    PYTEST="$WORK/.venv/bin/pytest"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
else
    fail "pytest not found — activate venv: cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install pytest"
fi

echo "Running hidden test suite..."
if $PYTEST "$WORK/tests/test_hidden.py" -v 2>&1; then
    echo
    echo "All tests passed. Submit this flag in the platform:"
    echo
    echo "    $FLAG"
else
    fail "hidden test suite has failures — fix your implementation and retry"
fi
