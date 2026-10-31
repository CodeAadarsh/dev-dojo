#!/usr/bin/env bash
# Plants the "Sliding Window Maximum" starter project into the work directory.
# Idempotent — re-running overwrites files but does not delete .venv.
set -euo pipefail

SLUG="01-sliding-window-max"
WORK="$HOME/.kube-dojo-work/$SLUG"
mkdir -p "$WORK/tests"

# ── solution.py skeleton ─────────────────────────────────────────────────────
cat > "$WORK/solution.py" << 'PYEOF'
# solution.py — sliding window maximum
# Given nums (list[int]) and k (int), return a list[int] of the maximum
# element in each contiguous window of size k.
# Example: nums=[1,3,-1,-3,5,3,6,7], k=3  →  [3,3,5,5,6,7]
#
# Constraints: 1 ≤ k ≤ len(nums) ≤ 10^5, -10^4 ≤ nums[i] ≤ 10^4
# Target: O(n) time, O(k) space

from typing import List


def sliding_window_max(nums: List[int], k: int) -> List[int]:
    # TODO: implement this function.
    # The brute-force O(n*k) nested max() loop is correct but too slow.
    # Hint: which elements can *never* be the maximum of any future window?
    raise NotImplementedError
PYEOF

# ── visible sample tests ─────────────────────────────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

cat > "$WORK/tests/test_sample.py" << 'PYEOF'
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from solution import sliding_window_max


def test_example_from_brief():
    assert sliding_window_max([1, 3, -1, -3, 5, 3, 6, 7], 3) == [3, 3, 5, 5, 6, 7]


def test_window_equals_length():
    # one window → one element in output
    assert sliding_window_max([4, 2, 1], 3) == [4]


def test_window_size_one():
    # k=1 → every element is its own max
    assert sliding_window_max([5, 3, 7, 1], 1) == [5, 3, 7, 1]
PYEOF

echo
echo "Work directory   : $WORK"
echo
echo "Task             : implement sliding_window_max() in solution.py"
echo "                   so all tests pass (3 visible + hidden edge cases)."
echo
echo "Prerequisites    :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate && pip install pytest"
echo
echo "Run sample tests : cd $WORK && .venv/bin/pytest tests/test_sample.py -v"
echo "Verify + flag    : bash courses/course-13-dsa-interviews/challenges/$SLUG/verify.sh"
