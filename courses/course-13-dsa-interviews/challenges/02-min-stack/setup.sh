#!/usr/bin/env bash
# Plants the "Min Stack" starter project into the work directory.
# Idempotent — re-running overwrites files but does not delete .venv.
set -euo pipefail

SLUG="02-min-stack"
WORK="$HOME/.kube-dojo-work/$SLUG"
mkdir -p "$WORK/tests"

# ── solution.py skeleton ─────────────────────────────────────────────────────
cat > "$WORK/solution.py" << 'PYEOF'
# solution.py — MinStack
# Design a stack where push, pop, top, and getMin all run in O(1) time.
#
# Constraints:
#   -2^31 ≤ val ≤ 2^31 - 1
#   pop/top/getMin are only called when the stack is non-empty.
#
# Example sequence:
#   push(5) → min=5  |  push(3) → min=3  |  push(7) → min=3
#   pop     → min=3  |  pop     → min=5  |  getMin  → 5


class MinStack:
    def __init__(self):
        # TODO: initialise your data structures here
        pass

    def push(self, val: int) -> None:
        # TODO: push val; also track what the minimum is at this stack depth
        raise NotImplementedError

    def pop(self) -> None:
        # TODO: remove the top element; the minimum must update correctly
        raise NotImplementedError

    def top(self) -> int:
        # TODO: return the top element without removing it
        raise NotImplementedError

    def getMin(self) -> int:
        # TODO: return the current minimum in O(1) — no scanning allowed
        raise NotImplementedError
PYEOF

# ── visible sample tests ─────────────────────────────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

cat > "$WORK/tests/test_sample.py" << 'PYEOF'
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from solution import MinStack


def test_basic_sequence():
    ms = MinStack()
    ms.push(5)
    assert ms.getMin() == 5
    ms.push(3)
    assert ms.getMin() == 3
    ms.push(7)
    assert ms.getMin() == 3   # 7 > 3, min stays 3
    ms.pop()
    assert ms.getMin() == 3   # 7 popped, 3 still on stack
    ms.pop()
    assert ms.getMin() == 5   # 3 popped, back to 5


def test_top_does_not_pop():
    ms = MinStack()
    ms.push(42)
    assert ms.top() == 42
    assert ms.top() == 42     # calling top twice; stack unchanged


def test_push_smaller_then_larger():
    ms = MinStack()
    ms.push(10)
    ms.push(2)
    ms.push(8)
    assert ms.getMin() == 2
    assert ms.top() == 8
PYEOF

echo
echo "Work directory   : $WORK"
echo
echo "Task             : implement MinStack in solution.py"
echo "                   so push/pop/top/getMin all pass (visible + hidden)."
echo
echo "Prerequisites    :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate && pip install pytest"
echo
echo "Run sample tests : cd $WORK && .venv/bin/pytest tests/test_sample.py -v"
echo "Verify + flag    : bash courses/course-13-dsa-interviews/challenges/$SLUG/verify.sh"
