#!/usr/bin/env bash
# Verifier for "Min Stack".
# Writes a hidden pytest suite, runs it against solution.py, and prints the
# flag only when every test passes.
# Exit 0 = solved, 1 = not yet.
set -uo pipefail

SLUG="02-min-stack"
WORK="$HOME/.kube-dojo-work/$SLUG"
FLAG='KUBE{min_stack_o1_getmin}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ]             || fail "work directory missing — run setup.sh first"
[ -f "$WORK/solution.py" ] || fail "solution.py not found — run setup.sh first"

cd "$WORK"

if [ -f ".venv/bin/pytest" ]; then
    PYTEST=".venv/bin/pytest"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
else
    fail "pytest not found — cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install pytest"
fi

mkdir -p _verify

cat > "_verify/test_hidden.py" << 'PYEOF'
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from solution import MinStack


def test_basic_push_getmin():
    ms = MinStack()
    ms.push(5)
    assert ms.getMin() == 5
    ms.push(3)
    assert ms.getMin() == 3
    ms.push(7)
    assert ms.getMin() == 3


def test_pop_restores_min():
    ms = MinStack()
    ms.push(5)
    ms.push(3)
    ms.push(7)
    ms.pop()           # removes 7, min still 3
    assert ms.getMin() == 3
    ms.pop()           # removes 3, min back to 5
    assert ms.getMin() == 5


def test_top_correct_after_multiple_pushes():
    ms = MinStack()
    for v in [10, 20, 30]:
        ms.push(v)
    assert ms.top() == 30


def test_top_does_not_mutate():
    ms = MinStack()
    ms.push(99)
    ms.top()
    ms.top()
    assert ms.top() == 99
    assert ms.getMin() == 99


def test_duplicate_values():
    ms = MinStack()
    ms.push(3)
    ms.push(3)
    ms.push(3)
    assert ms.getMin() == 3
    ms.pop()
    assert ms.getMin() == 3   # still 3 after popping a duplicate
    ms.pop()
    assert ms.getMin() == 3


def test_min_is_first_pushed():
    ms = MinStack()
    ms.push(1)
    ms.push(5)
    ms.push(10)
    assert ms.getMin() == 1
    ms.pop()
    assert ms.getMin() == 1
    ms.pop()
    assert ms.getMin() == 1


def test_negative_values():
    ms = MinStack()
    ms.push(-3)
    ms.push(0)
    ms.push(-5)
    assert ms.getMin() == -5
    ms.pop()
    assert ms.getMin() == -3


def test_single_element():
    ms = MinStack()
    ms.push(42)
    assert ms.top() == 42
    assert ms.getMin() == 42


def test_push_then_pop_to_one():
    ms = MinStack()
    ms.push(7)
    ms.push(2)
    ms.push(9)
    ms.pop()
    ms.pop()
    assert ms.top() == 7
    assert ms.getMin() == 7


def test_large_sequence():
    import random
    random.seed(99)
    vals = [random.randint(-1000, 1000) for _ in range(300)]
    ms = MinStack()
    reference = []
    for v in vals:
        ms.push(v)
        reference.append(v)
        assert ms.getMin() == min(reference), \
            f"after push({v}): expected min={min(reference)}, got {ms.getMin()}"
        assert ms.top() == v
    for _ in range(150):
        ms.pop()
        reference.pop()
        assert ms.getMin() == min(reference), \
            f"after pop: expected min={min(reference)}, got {ms.getMin()}"


def test_interleaved_push_pop_getmin():
    ms = MinStack()
    ms.push(5)
    ms.push(1)
    assert ms.getMin() == 1
    ms.push(3)
    assert ms.getMin() == 1
    ms.pop()
    assert ms.getMin() == 1
    ms.pop()
    assert ms.getMin() == 5
PYEOF

if $PYTEST "_verify/test_hidden.py" -q 2>&1; then
    rm -rf "_verify"
    echo
    echo "All tests passed. Submit this flag in the platform:"
    echo
    echo "    $FLAG"
else
    rm -rf "_verify"
    fail "test suite has failures — fix your implementation and retry"
fi
