#!/usr/bin/env bash
# Plants the "Top K Frequent Elements" starter project into the work directory.
# Idempotent — re-running overwrites files but does not delete .venv.
set -euo pipefail

SLUG="03-top-k-frequent"
WORK="$HOME/.kube-dojo-work/$SLUG"
mkdir -p "$WORK/tests"

# ── solution.py skeleton ─────────────────────────────────────────────────────
cat > "$WORK/solution.py" << 'PYEOF'
# solution.py — top k frequent elements
# Given nums (list[int]) and k (int), return a list[int] of the k elements
# that appear most frequently. Output order does not matter.
# Example: nums=[1,1,1,2,2,3], k=2  →  [1, 2]
#
# Constraints: 1 ≤ k ≤ |distinct elements| ≤ len(nums) ≤ 10^5
#              -10^4 ≤ nums[i] ≤ 10^4
# Target: O(n log k) with a heap, or O(n) with bucket sort.
# The answer is unique (no ties at the k-th boundary).

from typing import List


def top_k_frequent(nums: List[int], k: int) -> List[int]:
    # TODO: implement this function.
    # sorted(Counter(nums).items(), key=lambda x: -x[1])[:k] is O(n log n) —
    # you can do better. Think about what data structure lets you track
    # "the k largest things seen so far" without sorting everything.
    raise NotImplementedError
PYEOF

# ── visible sample tests ─────────────────────────────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

cat > "$WORK/tests/test_sample.py" << 'PYEOF'
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from solution import top_k_frequent


def test_example_k2():
    result = top_k_frequent([1, 1, 1, 2, 2, 3], 2)
    assert sorted(result) == [1, 2]


def test_single_element():
    assert top_k_frequent([1], 1) == [1]


def test_all_same_frequency_k1():
    # Only one distinct element — k=1 must return it
    result = top_k_frequent([7, 7, 7], 1)
    assert result == [7]
PYEOF

echo
echo "Work directory   : $WORK"
echo
echo "Task             : implement top_k_frequent() in solution.py"
echo "                   so all tests pass (3 visible + hidden edge cases)."
echo
echo "Prerequisites    :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate && pip install pytest"
echo
echo "Run sample tests : cd $WORK && .venv/bin/pytest tests/test_sample.py -v"
echo "Verify + flag    : bash courses/course-13-dsa-interviews/challenges/$SLUG/verify.sh"
