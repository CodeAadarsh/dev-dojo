#!/usr/bin/env bash
# Plants the "Merge Intervals" starter project into the work directory.
# Idempotent — re-running overwrites files but does not delete .venv.
set -euo pipefail

SLUG="01-coding-drill-arrays"
WORK="$HOME/.kube-dojo-work/$SLUG"
mkdir -p "$WORK/tests"

# ── solution.py skeleton ─────────────────────────────────────────────────────
cat > "$WORK/solution.py" << 'PYEOF'
# solution.py — merge intervals
# Given a list of intervals [[start, end], ...], merge all overlapping
# intervals and return the merged list sorted by start.
#
# Example:
#   merge_intervals([[1,3],[2,6],[8,10],[15,18]]) -> [[1,6],[8,10],[15,18]]
#   merge_intervals([[1,4],[4,5]])                -> [[1,5]]
#
# Constraints: 1 <= len(intervals) <= 10^4, 0 <= start <= end <= 10^4
# Target: O(n log n) time, O(n) space

from typing import List


def merge_intervals(intervals: List[List[int]]) -> List[List[int]]:
    # TODO: implement this function.
    # Step 1: sort by start.
    # Step 2: sweep — for each interval, either extend the current group
    #         or close it and start a new one.
    raise NotImplementedError
PYEOF

# ── visible sample tests ─────────────────────────────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

cat > "$WORK/tests/test_sample.py" << 'PYEOF'
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from solution import merge_intervals


def test_basic_overlap():
    assert merge_intervals([[1, 3], [2, 6], [8, 10], [15, 18]]) == [[1, 6], [8, 10], [15, 18]]


def test_touching_boundary():
    # [1,4] and [4,5] share the endpoint 4 — they merge
    assert merge_intervals([[1, 4], [4, 5]]) == [[1, 5]]


def test_unsorted_input():
    # Input not sorted by start — must sort first
    assert merge_intervals([[1, 4], [0, 4]]) == [[0, 4]]


def test_no_overlap():
    assert merge_intervals([[1, 2], [3, 4], [5, 6]]) == [[1, 2], [3, 4], [5, 6]]
PYEOF

echo
echo "Work directory   : $WORK"
echo
echo "Task             : implement merge_intervals() in solution.py"
echo "                   so all tests pass (4 visible + hidden edge cases)."
echo
echo "Prerequisites    :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate && pip install pytest"
echo
echo "Run sample tests : cd $WORK && .venv/bin/pytest tests/test_sample.py -v"
echo "Verify + flag    : bash courses/course-35-sde2-interview-loop/challenges/$SLUG/verify.sh"
