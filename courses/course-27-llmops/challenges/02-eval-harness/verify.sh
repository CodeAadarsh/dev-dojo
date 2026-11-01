#!/usr/bin/env bash
# Verifier for "Eval Harness".
# Writes a hidden pytest suite into the work dir, runs it, prints the flag only
# when every test passes. Exit 0 = solved, 1 = not yet.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/02-eval-harness"
FLAG='KUBE{eval_harness_score_gate}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ] || fail "work directory missing — run setup.sh first"
[ -f "$WORK/harness.py" ] || fail "harness.py not found in $WORK — run setup.sh first"

cd "$WORK"

# ── write the hidden test suite ───────────────────────────────────────────────
cat > "$WORK/_hidden_test_harness.py" << 'PYEOF'
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from harness import EvalHarness, EvalCase, EvalResult

# ── fixed golden dataset (deterministic seeds) ────────────────────────────────
GOLDEN = [
    EvalCase("What is 2+2?", "4"),
    EvalCase("Capital of France?", "Paris"),
    EvalCase("Hello in Spanish?", "Hola"),
]

# ── fixed mock models ──────────────────────────────────────────────────────────
_GOOD_ANSWERS = {
    "What is 2+2?": "4",
    "Capital of France?": "Paris",
    "Hello in Spanish?": "Hola",
}

def _good_model(inp: str) -> str:
    return _GOOD_ANSWERS.get(inp, "")

def _bad_model(inp: str) -> str:
    return "I don't know"

def _partial_model(inp: str) -> str:
    # Returns correct answers for the first two, wrong for the third.
    return _GOOD_ANSWERS.get(inp, "") if inp != "Hello in Spanish?" else "Ciao"

# ── deterministic exact-match judge ───────────────────────────────────────────
def _exact_judge(expected: str, actual: str) -> float:
    return 1.0 if expected.strip() == actual.strip() else 0.0


def test_run_populates_results():
    h = EvalHarness(_good_model, _exact_judge)
    h.run(GOLDEN)
    assert len(h.results) == len(GOLDEN), (
        f"expected {len(GOLDEN)} results, got {len(h.results)}"
    )
    for res in h.results:
        assert isinstance(res, EvalResult)


def test_good_model_aggregate_is_one():
    h = EvalHarness(_good_model, _exact_judge)
    h.run(GOLDEN)
    score = h.aggregate_score()
    assert abs(score - 1.0) < 1e-9, f"expected 1.0, got {score}"


def test_good_model_passes_threshold():
    h = EvalHarness(_good_model, _exact_judge, threshold=0.8)
    h.run(GOLDEN)
    assert h.passes_threshold(), "good model should pass threshold=0.8"


def test_bad_model_aggregate_is_zero():
    h = EvalHarness(_bad_model, _exact_judge)
    h.run(GOLDEN)
    score = h.aggregate_score()
    assert abs(score - 0.0) < 1e-9, f"expected 0.0, got {score}"


def test_bad_model_fails_threshold():
    h = EvalHarness(_bad_model, _exact_judge, threshold=0.5)
    h.run(GOLDEN)
    assert not h.passes_threshold(), "bad model should fail threshold=0.5"


def test_partial_model_score():
    h = EvalHarness(_partial_model, _exact_judge)
    h.run(GOLDEN)
    expected = 2.0 / 3.0
    score = h.aggregate_score()
    assert abs(score - expected) < 1e-9, f"expected {expected:.4f}, got {score:.4f}"


def test_partial_passes_low_threshold():
    h = EvalHarness(_partial_model, _exact_judge, threshold=0.5)
    h.run(GOLDEN)
    assert h.passes_threshold()


def test_partial_fails_high_threshold():
    h = EvalHarness(_partial_model, _exact_judge, threshold=0.8)
    h.run(GOLDEN)
    assert not h.passes_threshold()


def test_failing_cases_count():
    h = EvalHarness(_bad_model, _exact_judge, threshold=0.5)
    h.run(GOLDEN)
    failing = h.failing_cases()
    assert len(failing) == len(GOLDEN), (
        f"all cases should fail for bad model, got {len(failing)}"
    )


def test_failing_cases_partial():
    h = EvalHarness(_partial_model, _exact_judge, threshold=0.5)
    h.run(GOLDEN)
    failing = h.failing_cases()
    assert len(failing) == 1, f"only 1 case should fail for partial model, got {len(failing)}"


def test_aggregate_raises_when_empty():
    h = EvalHarness(_good_model, _exact_judge)
    raised = False
    try:
        h.aggregate_score()
    except ValueError:
        raised = True
    assert raised, "aggregate_score() must raise ValueError when results is empty"


def test_run_replaces_previous_results():
    h = EvalHarness(_good_model, _exact_judge)
    h.run(GOLDEN)
    h.run(GOLDEN[:1])
    assert len(h.results) == 1, "run() must replace previous results, not append"
PYEOF

# ── find pytest ───────────────────────────────────────────────────────────────
if [ -f ".venv/bin/pytest" ]; then
    PYTEST=".venv/bin/pytest"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
else
    fail "pytest not found — activate the venv: cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install pytest"
fi

if $PYTEST "$WORK/_hidden_test_harness.py" -q 2>&1; then
    echo
    echo "All tests passed. Submit this flag in the platform:"
    echo
    echo "    $FLAG"
else
    fail "test suite has failures — fix harness.py and retry"
fi
