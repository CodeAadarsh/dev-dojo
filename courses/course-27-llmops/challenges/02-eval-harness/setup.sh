#!/usr/bin/env bash
# Plants the "Eval Harness" starter project into the work directory.
# Idempotent — re-running overwrites source files but does not delete .venv.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/02-eval-harness"
mkdir -p "$WORK/tests"

# ── harness.py skeleton ───────────────────────────────────────────────────────
cat > "$WORK/harness.py" << 'PYEOF'
# harness.py — Eval Harness skeleton
#
# Implement every method body. The class shapes and type hints are provided;
# only the logic inside each method is stubbed with NotImplementedError.
#
# The harness is model-agnostic: model_fn and judge_fn are callables passed in
# at construction time, so no real LLM is required — just a Python function.

from typing import List, Callable


class EvalCase:
    """A single golden example: an input prompt and the expected output."""

    def __init__(self, input: str, expected: str) -> None:
        self.input = input
        self.expected = expected


class EvalResult:
    """The outcome of running the model on one EvalCase."""

    def __init__(self, case: EvalCase, actual: str, score: float) -> None:
        self.case = case    # the original EvalCase
        self.actual = actual  # what the model returned
        self.score = score   # judge's score, 0.0 – 1.0


class EvalHarness:
    """Runs model_fn over a list of EvalCases, scores with judge_fn, aggregates."""

    def __init__(
        self,
        model_fn: Callable[[str], str],
        judge_fn: Callable[[str, str], float],
        threshold: float = 0.7,
    ) -> None:
        self.model_fn = model_fn    # model_fn(input) -> str
        self.judge_fn = judge_fn    # judge_fn(expected, actual) -> float 0..1
        self.threshold = threshold  # minimum acceptable aggregate score
        self.results: List[EvalResult] = []

    def run(self, cases: List[EvalCase]) -> None:
        """Evaluate all cases; populate self.results.
        For each case: call model_fn(case.input), call judge_fn(case.expected, actual),
        append an EvalResult. Replaces any previous results."""
        raise NotImplementedError

    def aggregate_score(self) -> float:
        """Return the arithmetic mean of all result scores.
        Raise ValueError if self.results is empty."""
        raise NotImplementedError

    def passes_threshold(self) -> bool:
        """Return True iff aggregate_score() >= self.threshold."""
        raise NotImplementedError

    def failing_cases(self) -> List[EvalResult]:
        """Return results where score < self.threshold."""
        raise NotImplementedError
PYEOF

# ── golden.csv ────────────────────────────────────────────────────────────────
cat > "$WORK/golden.csv" << 'CSVEOF'
input,expected
"What is 2+2?","4"
"Capital of France?","Paris"
"Hello in Spanish?","Hola"
"Opposite of hot?","cold"
"Smallest prime?","2"
"Days in a week?","7"
"H2O is?","water"
"Boiling point of water (Celsius)?","100"
"Planet closest to the Sun?","Mercury"
"Speed of light unit?","c"
CSVEOF

# ── tests/test_harness_sample.py (visible sample harness) ────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

cat > "$WORK/tests/test_harness_sample.py" << 'PYEOF'
# Sample tests — run while developing.
# The verifier uses a separate, more comprehensive suite with fixed seeds.
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from harness import EvalHarness, EvalCase


CASES = [
    EvalCase("ping", "pong"),
    EvalCase("foo", "bar"),
]

def exact_judge(expected: str, actual: str) -> float:
    return 1.0 if expected.strip() == actual.strip() else 0.0

def good_model(inp: str) -> str:
    return {"ping": "pong", "foo": "bar"}[inp]

def bad_model(inp: str) -> str:
    return "wrong"


def test_run_populates_results():
    h = EvalHarness(good_model, exact_judge)
    h.run(CASES)
    assert len(h.results) == 2


def test_good_model_aggregate():
    h = EvalHarness(good_model, exact_judge)
    h.run(CASES)
    assert abs(h.aggregate_score() - 1.0) < 1e-9


def test_bad_model_fails_threshold():
    h = EvalHarness(bad_model, exact_judge, threshold=0.5)
    h.run(CASES)
    assert not h.passes_threshold()
PYEOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : implement all method bodies in harness.py so the"
echo "                 pytest harness passes."
echo
echo "Prerequisites  :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate"
echo "  pip install pytest"
echo
echo "Run sample tests : cd $WORK && .venv/bin/pytest tests/ -v"
echo "Verify + flag    : bash courses/course-27-llmops/challenges/02-eval-harness/verify.sh"
