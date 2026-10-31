#!/usr/bin/env bash
# Plants the "Course Schedule" starter project.
# Idempotent — re-running overwrites files but does not delete .venv.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/05-course-schedule"
mkdir -p "$WORK/tests"

# ── solution.py skeleton ─────────────────────────────────────────────────────
cat > "$WORK/solution.py" << 'PYEOF'
# solution.py — Course schedule cycle detection
# Implement can_finish using Kahn's BFS algorithm (or DFS with 3-color marking).
# Return True if all courses can be finished, False if a cycle exists.
from collections import deque


def can_finish(num_courses: int, prerequisites: list) -> bool:
    """
    num_courses: number of courses (0-indexed: 0 to num_courses-1)
    prerequisites: list of [course, prereq] — prereq must come before course
    Returns True if all courses can be finished (no cycle), False otherwise.
    """
    # TODO: detect whether the prerequisite graph has a cycle
    return True
PYEOF

# ── tests/__init__.py ────────────────────────────────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

# ── visible test harness ─────────────────────────────────────────────────────
cat > "$WORK/tests/test_schedule.py" << 'PYEOF'
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from solution import can_finish


def test_simple_no_cycle():
    assert can_finish(2, [[1, 0]]) is True


def test_simple_cycle():
    assert can_finish(2, [[1, 0], [0, 1]]) is False


def test_no_prerequisites():
    assert can_finish(5, []) is True


def test_chain_no_cycle():
    # 0 -> 1 -> 2 -> 3
    assert can_finish(4, [[1, 0], [2, 1], [3, 2]]) is True


def test_cycle_length_3():
    assert can_finish(3, [[0, 1], [1, 2], [2, 0]]) is False


def test_single_course():
    assert can_finish(1, []) is True


def test_dag_no_cycle():
    # diamond: 0 -> 1, 0 -> 2, 1 -> 3, 2 -> 3
    assert can_finish(4, [[1, 0], [2, 0], [3, 1], [3, 2]]) is True


def test_partial_cycle():
    # courses 0,1,2,3 — only 1 and 2 form a cycle
    assert can_finish(4, [[1, 0], [2, 1], [1, 2], [3, 0]]) is False
PYEOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : implement can_finish(num_courses, prerequisites) in solution.py"
echo "                 Return True if all courses can be finished (no cycle), False otherwise."
echo
echo "Prerequisites  :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate && pip install pytest"
echo
echo "Run tests      : cd $WORK && .venv/bin/pytest tests/ -v"
echo "Verify + flag  : bash courses/course-13-dsa-interviews/challenges/05-course-schedule/verify.sh"
