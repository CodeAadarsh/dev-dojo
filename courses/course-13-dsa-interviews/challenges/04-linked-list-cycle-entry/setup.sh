#!/usr/bin/env bash
# Plants the "Find the Cycle Entry" starter project.
# Idempotent — re-running overwrites files but does not delete .venv.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/04-linked-list-cycle-entry"
mkdir -p "$WORK/tests"

# ── solution.py skeleton ─────────────────────────────────────────────────────
cat > "$WORK/solution.py" << 'PYEOF'
# solution.py — Linked List cycle entry detection
# Implement detect_cycle_entry using Floyd's two-pointer algorithm.
# Do NOT use a hash set or modify the list.


class ListNode:
    def __init__(self, val: int = 0, next: "ListNode | None" = None):
        self.val = val
        self.next = next


def detect_cycle_entry(head: "ListNode | None") -> int:
    """Return the value of the cycle entry node, or -1 if no cycle."""
    # TODO: implement using fast/slow pointers only — no hash set, no list modification
    return -1
PYEOF

# ── tests/__init__.py ────────────────────────────────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

# ── tests/test_cycle.py (visible harness) ───────────────────────────────────
cat > "$WORK/tests/test_cycle.py" << 'PYEOF'
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from solution import ListNode, detect_cycle_entry


def make_list(values: list) -> ListNode:
    """Build a plain linked list (no cycle) from a list of values."""
    if not values:
        return None
    head = ListNode(values[0])
    cur = head
    for v in values[1:]:
        cur.next = ListNode(v)
        cur = cur.next
    return head


def attach_cycle(head: ListNode, entry_index: int) -> ListNode:
    """Make the tail point to the node at entry_index (0-based)."""
    nodes, cur = [], head
    while cur:
        nodes.append(cur)
        cur = cur.next
    nodes[-1].next = nodes[entry_index]   # create the cycle
    return head


def test_no_cycle():
    head = make_list([3, 2, 0, -4])
    assert detect_cycle_entry(head) == -1


def test_cycle_at_head():
    head = make_list([3, 2, 0, -4])
    attach_cycle(head, 0)       # tail -> head
    assert detect_cycle_entry(head) == 3


def test_cycle_at_index_1():
    head = make_list([3, 2, 0, -4])
    attach_cycle(head, 1)       # tail -> node(2)
    assert detect_cycle_entry(head) == 2


def test_single_node_self_loop():
    node = ListNode(1)
    node.next = node
    assert detect_cycle_entry(node) == 1


def test_single_node_no_cycle():
    node = ListNode(7)
    assert detect_cycle_entry(node) == -1


def test_empty_list():
    assert detect_cycle_entry(None) == -1


def test_two_node_cycle():
    a = ListNode(1)
    b = ListNode(2)
    a.next = b
    b.next = a           # cycle: b -> a
    assert detect_cycle_entry(a) == 1


def test_long_list_no_cycle():
    head = make_list(list(range(50)))
    assert detect_cycle_entry(head) == -1
PYEOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : implement detect_cycle_entry(head) in solution.py"
echo "                 using Floyd's algorithm only — no hash set."
echo
echo "Prerequisites  :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate && pip install pytest"
echo
echo "Run tests      : cd $WORK && .venv/bin/pytest tests/ -v"
echo "Verify + flag  : bash courses/course-13-dsa-interviews/challenges/04-linked-list-cycle-entry/verify.sh"
