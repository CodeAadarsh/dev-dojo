#!/usr/bin/env bash
# Verifier for "Course Schedule".
# Writes a hidden pytest suite at runtime, runs it against solution.py,
# prints the flag only when every test passes.
set -uo pipefail

SLUG="05-course-schedule"
WORK="$HOME/.kube-dojo-work/$SLUG"
FLAG='KUBE{topo_sort_detects_deadlock}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ] || fail "work directory missing — run setup.sh first"
[ -f "$WORK/solution.py" ] || fail "solution.py not found in $WORK — run setup.sh first"

cd "$WORK"

if [ -f ".venv/bin/pytest" ]; then
    PYTEST=".venv/bin/pytest"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
else
    fail "pytest not found — activate the venv: cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install pytest"
fi

HIDDEN_DIR="$WORK/.hidden_tests"
mkdir -p "$HIDDEN_DIR"

cat > "$HIDDEN_DIR/__init__.py" << 'PYEOF'
PYEOF

cat > "$HIDDEN_DIR/test_schedule_hidden.py" << 'PYEOF'
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from solution import can_finish


def test_empty_prereqs():
    assert can_finish(1, []) is True

def test_five_courses_no_prereqs():
    assert can_finish(5, []) is True

def test_two_courses_one_way():
    assert can_finish(2, [[1, 0]]) is True

def test_two_courses_cycle():
    assert can_finish(2, [[1, 0], [0, 1]]) is False

def test_three_chain():
    assert can_finish(3, [[1, 0], [2, 1]]) is True

def test_three_cycle():
    assert can_finish(3, [[0, 1], [1, 2], [2, 0]]) is False

def test_disconnected_no_cycle():
    prereqs = [[1, 0], [2, 1], [4, 3]]
    assert can_finish(5, prereqs) is True

def test_disconnected_cycle_in_one_component():
    prereqs = [[1, 0], [0, 1], [3, 2]]
    assert can_finish(4, prereqs) is False

def test_diamond_dag():
    prereqs = [[1, 0], [2, 0], [3, 1], [3, 2]]
    assert can_finish(4, prereqs) is True

def test_large_chain_no_cycle():
    n = 500
    prereqs = [[i + 1, i] for i in range(n - 1)]
    assert can_finish(n, prereqs) is True

def test_large_cycle_at_end():
    n = 500
    prereqs = [[i + 1, i] for i in range(n - 1)]
    prereqs.append([0, n - 1])
    assert can_finish(n, prereqs) is False

def test_wide_dag():
    prereqs = [[i, 0] for i in range(1, 100)]
    assert can_finish(100, prereqs) is True

def test_pair_cycle_in_larger_graph():
    prereqs = [[0, 1], [1, 0], [2, 3]]
    assert can_finish(4, prereqs) is False

def test_return_type_true():
    result = can_finish(2, [[1, 0]])
    assert result is True, f"expected True (bool), got {result!r}"

def test_return_type_false():
    result = can_finish(2, [[1, 0], [0, 1]])
    assert result is False, f"expected False (bool), got {result!r}"

def test_reversed_prereq_pair():
    assert can_finish(2, [[0, 1]]) is True

def test_zero_courses():
    assert can_finish(0, []) is True
PYEOF

if $PYTEST tests/ "$HIDDEN_DIR/" -q 2>&1; then
    echo
    echo "All tests passed. Submit this flag in the platform:"
    echo
    echo "    $FLAG"
else
    fail "test suite has failures — fix your implementation in $WORK/solution.py and retry"
fi
