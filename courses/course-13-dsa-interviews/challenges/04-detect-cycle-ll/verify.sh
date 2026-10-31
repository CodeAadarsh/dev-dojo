#!/usr/bin/env bash
# Verifier for "Detect Cycle in a Linked List".
# Writes a hidden pytest suite at runtime, runs it against solution.py,
# prints the flag only when every test passes.
set -uo pipefail

SLUG="04-detect-cycle-ll"
WORK="$HOME/.kube-dojo-work/$SLUG"
FLAG='KUBE{floyd_finds_the_cycle}'

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

# Write the hidden test suite at run time
HIDDEN_DIR="$WORK/.hidden_tests"
mkdir -p "$HIDDEN_DIR"

cat > "$HIDDEN_DIR/__init__.py" << 'PYEOF'
PYEOF

cat > "$HIDDEN_DIR/test_cycle_hidden.py" << 'PYEOF'
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from solution import has_cycle, build_list, ListNode


# ── basic correctness ────────────────────────────────────────────────────────

def test_empty():
    assert has_cycle(None) is False

def test_single_no_cycle():
    assert has_cycle(build_list([42], -1)) is False

def test_single_self_loop():
    n = ListNode(1)
    n.next = n
    assert has_cycle(n) is True

def test_two_nodes_cycle():
    assert has_cycle(build_list([1, 2], 0)) is True

def test_two_nodes_no_cycle():
    assert has_cycle(build_list([1, 2], -1)) is False

def test_classic_cycle_pos1():
    assert has_cycle(build_list([3, 2, 0, -4], 1)) is True

def test_classic_no_cycle():
    assert has_cycle(build_list([1, 2, 3, 4, 5], -1)) is False

# ── cycle at the very end (pos = last - 1) ───────────────────────────────────

def test_cycle_near_end():
    assert has_cycle(build_list(list(range(10)), 8)) is True

# ── cycle back to head (pos = 0) ─────────────────────────────────────────────

def test_cycle_to_head_long():
    assert has_cycle(build_list(list(range(100)), 0)) is True

# ── long list, no cycle ───────────────────────────────────────────────────────

def test_long_no_cycle():
    assert has_cycle(build_list(list(range(500)), -1)) is False

# ── cycle at various positions in a 20-node list ─────────────────────────────

def test_cycle_pos_0_long():
    assert has_cycle(build_list(list(range(20)), 0)) is True

def test_cycle_pos_5_long():
    assert has_cycle(build_list(list(range(20)), 5)) is True

def test_cycle_pos_19_self():
    # pos == last index → last node points to itself
    assert has_cycle(build_list(list(range(20)), 19)) is True

# ── return type must be bool, not truthy ─────────────────────────────────────

def test_return_type_false():
    result = has_cycle(build_list([1, 2, 3], -1))
    assert result is False, f"expected False (bool), got {result!r}"

def test_return_type_true():
    result = has_cycle(build_list([1, 2], 0))
    assert result is True, f"expected True (bool), got {result!r}"

# ── negative values ───────────────────────────────────────────────────────────

def test_negative_values_cycle():
    assert has_cycle(build_list([-5, -3, -1, -2], 1)) is True

def test_negative_values_no_cycle():
    assert has_cycle(build_list([-5, -3, -1, -2], -1)) is False
PYEOF

if $PYTEST "$HIDDEN_DIR/" -q 2>&1; then
    echo
    echo "All tests passed. Submit this flag in the platform:"
    echo
    echo "    $FLAG"
else
    fail "test suite has failures — fix your implementation in $WORK/solution.py and retry"
fi
