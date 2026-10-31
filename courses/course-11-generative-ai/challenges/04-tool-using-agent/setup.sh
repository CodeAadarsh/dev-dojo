#!/usr/bin/env bash
# Plants the "Tool-Using Agent" challenge: mock model, tool registry, agent skeleton.
# Idempotent — re-running overwrites source files but preserves .venv.
set -euo pipefail

SLUG="04-tool-using-agent"
WORK="$HOME/.kube-dojo-work/$SLUG"
mkdir -p "$WORK"

# ── tools.py ──────────────────────────────────────────────────────────────────
cat > "$WORK/tools.py" << 'PYEOF'
"""
Tool registry for the stock-price lookup agent.

CALL_LOG records every invocation as (tool_name, args_dict).
The hidden pytest suite imports this to assert the tools were actually called.
"""

# Invocation log — do not remove or rename this variable.
CALL_LOG = []

_PRICES = {
    "AAPL": 150.0,
    "GOOG": 280.0,
    "MSFT": 320.0,
}


def lookup_stock_price(ticker: str) -> float:
    """Return the current price for ticker. Logs the call to CALL_LOG."""
    CALL_LOG.append(("lookup_stock_price", {"ticker": ticker}))
    if ticker not in _PRICES:
        raise ValueError(f"unknown ticker: {ticker!r}")
    return _PRICES[ticker]
PYEOF

# ── mock_model.py ─────────────────────────────────────────────────────────────
cat > "$WORK/mock_model.py" << 'PYEOF'
"""
Deterministic mock LLM for testing.

The model always drives the same three-step sequence regardless of the
question — two tool calls followed by a final text answer.  This makes
the agent loop fully testable without a live model.

_call_count is used by the hidden test suite to verify the loop called the
model the correct number of times.  Do not rename it.
"""

_RESPONSES = [
    {
        "type": "tool_call",
        "tool": "lookup_stock_price",
        "args": {"ticker": "AAPL"},
    },
    {
        "type": "tool_call",
        "tool": "lookup_stock_price",
        "args": {"ticker": "GOOG"},
    },
    {
        "type": "text",
        "content": (
            "The combined value is $2900.00 "
            "(10 shares of AAPL at $150.00 + 5 shares of GOOG at $280.00)."
        ),
    },
]

# Do not rename — imported by the hidden test suite.
_call_count = 0


def chat(messages: list) -> dict:
    """Return the next scripted response from the mock model."""
    global _call_count
    if _call_count >= len(_RESPONSES):
        return {"type": "text", "content": "done"}
    resp = _RESPONSES[_call_count]
    _call_count += 1
    return resp
PYEOF

# ── agent.py skeleton ─────────────────────────────────────────────────────────
cat > "$WORK/agent.py" << 'PYEOF'
"""
Tool-using agent skeleton.

Implement run_agent() so the function-calling loop works correctly:
  1. Send messages to the model via chat().
  2. If the model returns a tool_call, dispatch to TOOL_REGISTRY and append
     the result to messages, then loop.
  3. If the model returns text, return it as the final answer.
"""

from mock_model import chat
import tools

TOOL_REGISTRY = {
    "lookup_stock_price": tools.lookup_stock_price,
}


def run_agent(question: str) -> str:
    """
    Drive the agent loop until the model returns a text response.

    Args:
        question: the user's question as a plain string.

    Returns:
        The model's final text answer.

    Loop contract:
        response = chat(messages)
        if response["type"] == "tool_call":
            result = TOOL_REGISTRY[response["tool"]](**response["args"])
            messages.append({"role": "tool", "content": str(result)})
            # continue looping
        elif response["type"] == "text":
            return response["content"]
    """
    raise NotImplementedError("implement run_agent()")
PYEOF

# ── sample_test.py (visible to learner) ───────────────────────────────────────
cat > "$WORK/sample_test.py" << 'PYEOF'
"""
Lightweight checks for local development.
The full hidden suite in verify.sh is stricter — pass these first.
"""
import tools
import mock_model


def _reset():
    tools.CALL_LOG.clear()
    mock_model._call_count = 0


def test_tool_registry_has_lookup():
    from agent import TOOL_REGISTRY
    assert "lookup_stock_price" in TOOL_REGISTRY, \
        "TOOL_REGISTRY must contain 'lookup_stock_price'"


def test_run_agent_returns_string():
    _reset()
    from agent import run_agent
    result = run_agent("What is the combined value of 10 AAPL and 5 GOOG shares?")
    assert isinstance(result, str), \
        f"run_agent must return a str, got {type(result).__name__}"
PYEOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : implement run_agent() in agent.py so the function-calling"
echo "                 loop drives the mock model through two tool calls and"
echo "                 returns the final text answer."
echo
echo "Prerequisites  :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate"
echo "  pip install pytest"
echo
echo "Dev loop       : cd $WORK && .venv/bin/pytest sample_test.py -v"
echo "Verify + flag  : bash courses/course-11-generative-ai/challenges/$SLUG/verify.sh"
