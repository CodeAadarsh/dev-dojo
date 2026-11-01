#!/usr/bin/env bash
# Plants the "Tool Routing Agent" starter into the work directory.
# Idempotent — re-running overwrites stub and tests but does not delete .venv.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/05-tool-routing-agent"
mkdir -p "$WORK/tests"

# ── agent.py skeleton ─────────────────────────────────────────────────────────
cat > "$WORK/agent.py" << 'PYEOF'
# agent.py — tool-routing agent skeleton
#
# MOCK_PLANNER, TOOLS, and StepBudgetExceeded are provided and deterministic.
# Implement run_agent(query, max_steps) only.
#
# Agent loop contract:
#   1. Call MOCK_PLANNER(query, history) → action dict
#   2. action["action"] == "tool_call":
#        - look up TOOLS[action["tool"]] (raise ValueError if missing)
#        - call it with **action["args"]
#        - append {"tool": ..., "args": ..., "result": ...} to history
#        - loop
#   3. action["action"] == "answer":
#        - return action["value"]
#   4. After max_steps tool calls without an answer: raise StepBudgetExceeded
#
# The history list is the sole state carrier between planner calls.
# An empty or stale history causes the planner to repeat the same step forever.

import re as _re
from typing import Any, List, Dict


# ── mock tools (provided; do not modify) ──────────────────────────────────────

def _calculator(expr: str) -> float:
    """Safe arithmetic: digits, spaces, + - * / . ( ) only."""
    if not _re.match(r'^[\d\s\+\-\*\/\.\(\)]+$', expr):
        raise ValueError(f"Unsafe expression: {expr!r}")
    return float(eval(expr))  # noqa: S307 — pattern-validated above


_KNOWLEDGE_BASE: Dict[str, str] = {
    "france_capital":  "Paris",
    "germany_capital": "Berlin",
    "japan_capital":   "Tokyo",
    "spain_capital":   "Madrid",
}


def _lookup(key: str) -> str:
    return _KNOWLEDGE_BASE.get(key, "not_found")


TOOLS: Dict[str, Any] = {
    "calculator": _calculator,
    "lookup":     _lookup,
}


# ── mock planner (provided; do not modify) ────────────────────────────────────
# Fully deterministic: the action at each step is a function of (query, step).
# history[N]["result"] is the tool result from step N.

def MOCK_PLANNER(query: str, history: List[dict]) -> dict:
    step = len(history)

    if query == "what is 6 multiplied by 7":
        if step == 0:
            return {"action": "tool_call", "tool": "calculator", "args": {"expr": "6*7"}}
        return {"action": "answer", "value": str(int(history[0]["result"]))}

    if query == "capital of japan":
        if step == 0:
            return {"action": "tool_call", "tool": "lookup", "args": {"key": "japan_capital"}}
        return {"action": "answer", "value": history[0]["result"]}

    if query == "chain: capital then length":
        # Step 0: look up Spain's capital
        # Step 1: calculate the length of that city name
        # Step 2: return the length as the answer
        if step == 0:
            return {"action": "tool_call", "tool": "lookup", "args": {"key": "spain_capital"}}
        if step == 1:
            city = history[0]["result"]           # "Madrid"
            return {"action": "tool_call", "tool": "calculator",
                    "args": {"expr": str(len(city))}}   # len("Madrid") = 6
        return {"action": "answer", "value": str(int(history[1]["result"]))}

    if query == "infinite_loop":
        # Always asks for another tool call — used to test budget enforcement
        return {"action": "tool_call", "tool": "calculator", "args": {"expr": "1+1"}}

    return {"action": "answer", "value": "unknown"}


# ── exception (provided; raise this when budget exceeded) ────────────────────

class StepBudgetExceeded(RuntimeError):
    """Raised when run_agent exhausts max_steps without an answer action."""


# ── agent loop (implement this) ───────────────────────────────────────────────

def run_agent(query: str, max_steps: int = 5) -> str:
    """
    Drive MOCK_PLANNER through the tool-call / answer cycle.

    Args:
        query:     query string passed unchanged to MOCK_PLANNER each step
        max_steps: maximum number of tool calls allowed before StepBudgetExceeded

    Returns:
        The final answer string from the planner's 'answer' action.

    Raises:
        StepBudgetExceeded: planner issued more than max_steps tool calls
        ValueError:         planner named a tool not present in TOOLS
    """
    raise NotImplementedError("Implement run_agent()")
PYEOF

# ── tests/__init__.py ─────────────────────────────────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

# ── tests/test_agent.py ───────────────────────────────────────────────────────
cat > "$WORK/tests/test_agent.py" << 'PYEOF'
import sys
import os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import pytest
from agent import run_agent, StepBudgetExceeded


def test_routes_to_calculator():
    result = run_agent("what is 6 multiplied by 7", max_steps=5)
    assert result == "42", f"Expected '42', got {result!r}"


def test_routes_to_lookup():
    result = run_agent("capital of japan", max_steps=5)
    assert result == "Tokyo", f"Expected 'Tokyo', got {result!r}"


def test_two_step_chain():
    # lookup Spain's capital (step 1) -> calculator for len("Madrid") (step 2) -> "6"
    result = run_agent("chain: capital then length", max_steps=5)
    assert result == "6", (
        f"Expected '6' (len of 'Madrid'), got {result!r}. "
        "Hint: if history is not populated, the planner cannot progress past step 1."
    )


def test_step_budget_enforced():
    with pytest.raises(StepBudgetExceeded):
        run_agent("infinite_loop", max_steps=3)


def test_budget_not_exceeded_on_normal_query():
    # A 1-tool-call query must complete well within a generous budget
    result = run_agent("capital of japan", max_steps=10)
    assert result is not None and result != ""


def test_unknown_tool_raises():
    import agent
    original_planner = agent.MOCK_PLANNER

    def bad_planner(query, history):
        return {"action": "tool_call", "tool": "nonexistent_tool", "args": {}}

    agent.MOCK_PLANNER = bad_planner
    try:
        with pytest.raises((ValueError, KeyError)):
            run_agent("anything", max_steps=1)
    finally:
        agent.MOCK_PLANNER = original_planner
PYEOF

echo
echo "Work directory  : $WORK"
echo
echo "Task            : implement run_agent() in $WORK/agent.py"
echo "                  so all 6 tests pass."
echo
echo "Prerequisites   :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate"
echo "  pip install pytest"
echo
echo "Run tests       : cd $WORK && .venv/bin/pytest tests/ -v"
echo "Verify + flag   : bash courses/course-27-llmops/challenges/05-tool-routing-agent/verify.sh"
