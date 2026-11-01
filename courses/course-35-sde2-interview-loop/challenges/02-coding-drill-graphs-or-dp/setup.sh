#!/usr/bin/env bash
# Plants the "Longest Increasing Path" starter project into the work directory.
# Idempotent — re-running overwrites files but does not delete .venv.
set -euo pipefail

SLUG="02-coding-drill-graphs-or-dp"
WORK="$HOME/.kube-dojo-work/$SLUG"
mkdir -p "$WORK/tests"

# ── solution.py skeleton ─────────────────────────────────────────────────────
cat > "$WORK/solution.py" << 'PYEOF'
# solution.py — longest increasing path in a matrix
# Given an m×n integer matrix, return the length of the longest path along
# which each next value is strictly greater than the previous.
# Movement: 4 cardinal directions (up, down, left, right). No revisiting.
#
# Example:
#   [[9,9,4],[6,6,8],[2,1,1]] -> 4  (path: 1->2->6->9)
#   [[3,4,5],[3,2,6],[2,2,1]] -> 6  (path: 1->2->3->4->5->6)
#
# Target: O(m*n) time with memoization, O(m*n) space
import sys
sys.setrecursionlimit(200 * 200 + 10)

from typing import List


def longest_increasing_path(matrix: List[List[int]]) -> int:
    # TODO: implement this function.
    # DFS from every cell; memoize the result for each (r, c).
    # Key insight: strictly increasing path has no cycles, so no visited set
    # is needed per path — memoization is safe.
    raise NotImplementedError
PYEOF

# ── visible sample tests ─────────────────────────────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

cat > "$WORK/tests/test_sample.py" << 'PYEOF'
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from solution import longest_increasing_path


def test_example_a():
    matrix = [[9, 9, 4], [6, 6, 8], [2, 1, 1]]
    assert longest_increasing_path(matrix) == 4


def test_example_b():
    matrix = [[1, 2, 3], [6, 5, 4]]
    assert longest_increasing_path(matrix) == 6


def test_single_cell():
    assert longest_increasing_path([[42]]) == 1


def test_all_equal():
    # No strictly increasing path possible — every path is length 1
    assert longest_increasing_path([[5, 5], [5, 5]]) == 1
PYEOF

echo
echo "Work directory   : $WORK"
echo
echo "Task             : implement longest_increasing_path() in solution.py"
echo "                   so all tests pass (4 visible + hidden edge cases)."
echo
echo "Prerequisites    :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate && pip install pytest"
echo
echo "Run sample tests : cd $WORK && .venv/bin/pytest tests/test_sample.py -v"
echo "Verify + flag    : bash courses/course-35-sde2-interview-loop/challenges/$SLUG/verify.sh"
