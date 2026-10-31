#!/usr/bin/env bash
# Verifier for "Tool-Using Agent".
# Runs a hidden pytest suite; prints the flag only when all checks pass.
set -uo pipefail

SLUG="04-tool-using-agent"
WORK="$HOME/.kube-dojo-work/$SLUG"
FLAG='KUBE{tool_calling_closes_the_loop}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ] || fail "work dir $WORK missing — run setup.sh first"
[ -f "$WORK/agent.py" ]      || fail "agent.py not found in $WORK"
[ -f "$WORK/tools.py" ]      || fail "tools.py missing — run setup.sh first"
[ -f "$WORK/mock_model.py" ] || fail "mock_model.py missing — run setup.sh first"

if [ -f "$WORK/.venv/bin/pytest" ]; then
    PYTEST="$WORK/.venv/bin/pytest"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
else
    fail "pytest not found — run: cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install pytest"
fi

# Write the hidden test suite to a temp file so it is never in the repo.
TMPDIR_SUITE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_SUITE"' EXIT

cat > "$TMPDIR_SUITE/test_hidden.py" << 'PYEOF'
"""Hidden verifier suite — do not edit."""
import sys
import os

# Ensure WORK is on the path so agent/tools/mock_model are importable.
WORK = os.path.expanduser("~/.kube-dojo-work/04-tool-using-agent")
sys.path.insert(0, WORK)

import pytest
import tools
import mock_model


@pytest.fixture(autouse=True)
def reset_state():
    tools.CALL_LOG.clear()
    mock_model._call_count = 0
    yield


from agent import run_agent

QUESTION = "What is the combined value of 10 shares of AAPL and 5 shares of GOOG?"


def test_aapl_was_looked_up():
    run_agent(QUESTION)
    tickers = [args["ticker"] for _, args in tools.CALL_LOG]
    assert "AAPL" in tickers, \
        f"lookup_stock_price('AAPL') was never called; call log: {tools.CALL_LOG}"


def test_goog_was_looked_up():
    run_agent(QUESTION)
    tickers = [args["ticker"] for _, args in tools.CALL_LOG]
    assert "GOOG" in tickers, \
        f"lookup_stock_price('GOOG') was never called; call log: {tools.CALL_LOG}"


def test_model_called_three_times():
    run_agent(QUESTION)
    assert mock_model._call_count == 3, (
        f"Expected 3 model calls (2 tool_calls + 1 text), "
        f"got {mock_model._call_count}. "
        "Hint: the loop must continue after each tool_call response."
    )


def test_final_answer_contains_2900():
    answer = run_agent(QUESTION)
    assert "2900" in answer, \
        f"Expected final answer to contain '2900', got: {answer!r}"
PYEOF

cd "$WORK"
"$PYTEST" "$TMPDIR_SUITE/test_hidden.py" -v --tb=short \
    || fail "one or more checks failed — fix agent.py and retry"

echo
echo "All agent checks passed. Submit this flag in the platform:"
echo
echo "    $FLAG"
