#!/usr/bin/env bash
# Verifier for "Find the Cycle Entry".
# Runs a hidden pytest suite (written at run time) against solution.py.
# Prints the flag only when all tests pass.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/04-linked-list-cycle-entry"
FLAG='KUBE{floyd_finds_the_entry_node}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ] || fail "work directory missing — run setup.sh first"
[ -f "$WORK/solution.py" ] || fail "solution.py not found — run setup.sh first"

cd "$WORK"

if [ -f ".venv/bin/pytest" ]; then
    PYTEST=".venv/bin/pytest"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
else
    fail "pytest not found — activate the venv: cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install pytest"
fi

# ── hidden test suite (written at verify time) ───────────────────────────────
HIDDEN_DIR="$WORK/.hidden_tests"
mkdir -p "$HIDDEN_DIR"

cat > "$HIDDEN_DIR/test_hidden_cycle.py" << 'PYEOF'
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from solution import ListNode, detect_cycle_entry


def make_list(values):
    if not values:
        return None
    head = ListNode(values[0])
    cur = head
    for v in values[1:]:
        cur.next = ListNode(v)
        cur = cur.next
    return head


def attach_cycle(head, entry_index):
    nodes, cur = [], head
    while cur:
        nodes.append(cur)
        cur = cur.next
    nodes[-1].next = nodes[entry_index]
    return head


def test_cycle_middle_long_list():
    # cycle entry at index 3 in a 10-node list
    head = make_list([10, 20, 30, 40, 50, 60, 70, 80, 90, 100])
    attach_cycle(head, 3)
    assert detect_cycle_entry(head) == 40


def test_cycle_last_index():
    head = make_list([1, 2, 3, 4, 5])
    attach_cycle(head, 4)    # tail self-loop
    assert detect_cycle_entry(head) == 5


def test_cycle_entry_index_2():
    head = make_list([5, 4, 3, 2, 1])
    attach_cycle(head, 2)
    assert detect_cycle_entry(head) == 3


def test_no_cycle_large():
    head = make_list(list(range(200)))
    assert detect_cycle_entry(head) == -1


def test_two_nodes_no_cycle():
    head = make_list([99, 100])
    assert detect_cycle_entry(head) == -1


def test_cycle_unique_values():
    # ensure implementation returns NODE VALUE not index
    head = make_list([7, 14, 21, 28, 35])
    attach_cycle(head, 2)
    result = detect_cycle_entry(head)
    assert result == 21, f"expected 21 (the node value), got {result}"


def test_hash_set_forbidden():
    import inspect
    from solution import detect_cycle_entry as fn
    src = inspect.getsource(fn)
    forbidden = ["set()", "{}", "dict()", "defaultdict", "Counter("]
    for token in forbidden:
        assert token not in src, (
            f"Solution must use O(1) space (no {token!r}). "
            "Use Floyd's two-pointer algorithm only."
        )
PYEOF

if $PYTEST "$HIDDEN_DIR/" tests/ -q 2>&1; then
    echo
    echo "All tests passed. Submit this flag in the platform:"
    echo
    echo "    $FLAG"
else
    fail "test suite has failures — fix your implementation and retry"
fi
