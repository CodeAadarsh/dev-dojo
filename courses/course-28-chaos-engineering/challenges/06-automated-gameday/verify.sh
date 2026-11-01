#!/usr/bin/env bash
# Verifier for "Automated GameDay Runner".
# Writes a hidden pytest suite into the work directory, runs it, and prints
# the flag only when all tests pass. Exit 0 = solved, 1 = not yet.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/06-automated-gameday"
FLAG='KUBE{automated_gameday_abort_on_slo_breach}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ]           || fail "work directory missing — run setup.sh first"
[ -f "$WORK/system.py" ] || fail "system.py missing — run setup.sh first"
[ -f "$WORK/gameday.py" ] || fail "gameday.py missing — run setup.sh first"

cd "$WORK"

# ── write the hidden test suite ──────────────────────────────────────────────
cat > "$WORK/tests/test_hidden.py" << 'PYEOF'
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from system import MockSystem
from gameday import run_gameday, ExperimentReport


def test_aborts_on_slo_breach():
    # fault_success_rate=0.40, threshold=0.95 — must breach and abort
    sys_ = MockSystem(healthy_success_rate=0.999, fault_success_rate=0.40)
    report = run_gameday(sys_, slo_threshold=0.95, n_baseline=500, n_monitor=200, experiment_label='test-breach')
    assert report.aborted is True, "should abort when fault causes SLO breach"
    assert report.abort_reason == 'slo_breach', \
        f"abort_reason must be 'slo_breach', got {report.abort_reason!r}"
    # verify rollback event was emitted
    rollback_events = [e for e in sys_.events if e[0] == 'rollback']
    assert len(rollback_events) >= 1, "rollback must be called on abort"
    assert rollback_events[0][1] == 'test-breach', \
        f"rollback label must match experiment_label, got {rollback_events[0][1]!r}"


def test_does_not_abort_when_healthy():
    # fault_success_rate=0.98, threshold=0.95 — fault stays above threshold
    sys_ = MockSystem(healthy_success_rate=0.999, fault_success_rate=0.98)
    report = run_gameday(sys_, slo_threshold=0.95, n_baseline=500, n_monitor=200, experiment_label='test-healthy')
    assert report.aborted is False, \
        f"should NOT abort when fault keeps SLO above threshold (fault_period_slo={report.fault_period_slo})"
    assert report.steady_state_after is not None, \
        "steady_state_after must be set when experiment completes without abort"


def test_aborted_report_has_no_steady_state_after():
    # When aborted, steady_state_after must not be measured
    sys_ = MockSystem(healthy_success_rate=0.999, fault_success_rate=0.40)
    report = run_gameday(sys_, slo_threshold=0.95, n_baseline=500, n_monitor=200)
    assert report.aborted is True
    assert report.steady_state_after is None, \
        "steady_state_after must be None when aborted — system is still recovering"


def test_report_captures_before_and_after():
    sys_ = MockSystem(healthy_success_rate=0.999, fault_success_rate=0.98)
    report = run_gameday(sys_, slo_threshold=0.95, n_baseline=500, n_monitor=200)
    d = report.to_dict()
    assert d['steady_state_before'] is not None, "steady_state_before must be recorded"
    assert d['steady_state_before'] > 0.90, \
        f"baseline should be near 99.9%, got {d['steady_state_before']:.4f}"
    assert d['steady_state_after'] is not None, "steady_state_after must be recorded"
    assert d['fault_period_slo'] is not None, "fault_period_slo must be recorded"


def test_fault_period_slo_is_minimum():
    # With consistent 98% fault rate, fault_period_slo should reflect the min sample
    sys_ = MockSystem(healthy_success_rate=0.999, fault_success_rate=0.98)
    report = run_gameday(sys_, slo_threshold=0.95, n_baseline=500, n_monitor=300)
    # All 3 samples should be near 98%; min is still above 0.90
    assert report.fault_period_slo is not None
    assert report.fault_period_slo > 0.90, \
        f"fault_period_slo should be near 98% fault rate, got {report.fault_period_slo:.4f}"


def test_fault_always_removed_on_abort():
    sys_ = MockSystem(healthy_success_rate=0.999, fault_success_rate=0.40)
    run_gameday(sys_, slo_threshold=0.95, n_baseline=500, n_monitor=200)
    assert sys_.fault_active is False, "fault must be deactivated even when aborting"


def test_fault_always_removed_on_clean_completion():
    sys_ = MockSystem(healthy_success_rate=0.999, fault_success_rate=0.98)
    run_gameday(sys_, slo_threshold=0.95, n_baseline=500, n_monitor=200)
    assert sys_.fault_active is False, "fault must be deactivated on clean completion"


def test_inject_before_rollback_event_order():
    # The audit trail must show fault_injected before rollback
    sys_ = MockSystem(healthy_success_rate=0.999, fault_success_rate=0.40)
    run_gameday(sys_, slo_threshold=0.95, n_baseline=200, n_monitor=100, experiment_label='order-test')
    event_types = [e[0] for e in sys_.events]
    fi_idx = next((i for i, t in enumerate(event_types) if t == 'fault_injected'), -1)
    rb_idx = next((i for i, t in enumerate(event_types) if t == 'rollback'), -1)
    assert fi_idx != -1, "fault_injected event not found in system.events"
    assert rb_idx != -1, "rollback event not found in system.events"
    assert fi_idx < rb_idx, "fault_injected must appear before rollback in the event log"
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
