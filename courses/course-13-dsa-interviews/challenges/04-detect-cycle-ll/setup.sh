#!/usr/bin/env bash
# Plants the "Detect Cycle in a Linked List" starter project.
# Idempotent — re-running overwrites source files but does not delete .venv.
set -euo pipefail

SLUG="04-detect-cycle-ll"
WORK="$HOME/.kube-dojo-work/$SLUG"
mkdir -p "$WORK/tests"

# ── solution.py skeleton ─────────────────────────────────────────────────────
cat > "$WORK/solution.py" << 'PYEOF'
# solution.py — Detect Cycle in a Linked List
# Implement has_cycle(head) using Floyd's two-pointer algorithm.
# O(n) time, O(1) space — no set/dict/list to track visited nodes.

class ListNode:
    def __init__(self, val: int = 0, next: "ListNode | None" = None):
        self.val = val
        self.next = next


def build_list(values: list[int], pos: int) -> ListNode | None:
    """
    Build a linked list from `values`. If pos >= 0, the tail's next pointer
    is wired back to the node at index `pos` (0-based), forming a cycle.
    Returns the head node, or None for an empty list.
    """
    if not values:
        return None
    nodes = [ListNode(v) for v in values]
    for i in range(len(nodes) - 1):
        nodes[i].next = nodes[i + 1]
    if pos >= 0:
        nodes[-1].next = nodes[pos]
    return nodes[0]


def has_cycle(head: ListNode | None) -> bool:
    # TODO: Implement using the tortoise-and-hare (Floyd's) algorithm.
    # Start both slow and fast at head.
    # Advance slow by 1, fast by 2 each iteration.
    # If they ever meet, a cycle exists.
    # If fast reaches None (or fast.next is None), no cycle.
    raise NotImplementedError("implement has_cycle")
PYEOF

# ── tests/test_cycle.py (visible harness) ────────────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

cat > "$WORK/tests/test_cycle.py" << 'PYEOF'
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from solution import has_cycle, build_list


def test_cycle_at_pos_1():
    head = build_list([3, 2, 0, -4], pos=1)
    assert has_cycle(head) is True, "list [3->2->0->-4->back to 2] must be a cycle"


def test_cycle_at_pos_0():
    head = build_list([1, 2], pos=0)
    assert has_cycle(head) is True, "list [1->2->back to 1] must be a cycle"


def test_single_no_cycle():
    head = build_list([1], pos=-1)
    assert has_cycle(head) is False, "single-node list with no cycle should be False"


def test_no_cycle():
    head = build_list([1, 2, 3, 4, 5], pos=-1)
    assert has_cycle(head) is False, "linear list should not be a cycle"


def test_empty_list():
    assert has_cycle(None) is False, "empty list (None head) should be False"
PYEOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : implement has_cycle(head) in solution.py using Floyd's"
echo "                 tortoise-and-hare algorithm (O(n) time, O(1) space)."
echo "                 The ListNode class and build_list helper are ready — do"
echo "                 not modify them, only fill in has_cycle."
echo
echo "Prerequisites  :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate"
echo "  pip install pytest"
echo
echo "Run tests      : cd $WORK && .venv/bin/pytest tests/ -v"
echo "Verify + flag  : bash courses/course-13-dsa-interviews/challenges/$SLUG/verify.sh"
