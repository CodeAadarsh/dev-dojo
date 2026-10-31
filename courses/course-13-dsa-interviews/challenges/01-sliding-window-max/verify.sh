#!/usr/bin/env bash
# Verifier for "Sliding Window Maximum".
# Writes a hidden pytest suite, runs it against solution.py, and prints the
# flag only when every test passes.
# Exit 0 = solved, 1 = not yet.
set -uo pipefail

SLUG="01-sliding-window-max"
WORK="$HOME/.kube-dojo-work/$SLUG"
FLAG='KUBE{sliding_window_max_deque}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ]       || fail "work directory missing — run setup.sh first"
[ -f "$WORK/solution.py" ] || fail "solution.py not found — run setup.sh first"

cd "$WORK"

if [ -f ".venv/bin/pytest" ]; then
    PYTEST=".venv/bin/pytest"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
else
    fail "pytest not found — cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install pytest"
fi

mkdir -p _verify

cat > "_verify/test_hidden.py" << 'PYEOF'
import sys, os, random
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from solution import sliding_window_max


def _oracle(nums, k):
    return [max(nums[i:i+k]) for i in range(len(nums) - k + 1)]


def test_example():
    assert sliding_window_max([1, 3, -1, -3, 5, 3, 6, 7], 3) == [3, 3, 5, 5, 6, 7]


def test_k_equals_1():
    nums = [5, 3, 7, 1, 9, 2]
    assert sliding_window_max(nums, 1) == nums


def test_k_equals_len():
    assert sliding_window_max([4, 2, 1], 3) == [4]


def test_single_element():
    assert sliding_window_max([42], 1) == [42]


def test_all_same():
    assert sliding_window_max([5, 5, 5, 5, 5], 3) == [5, 5, 5]


def test_strictly_descending():
    assert sliding_window_max([9, 8, 7, 6, 5], 3) == [9, 8, 7]


def test_strictly_ascending():
    assert sliding_window_max([1, 2, 3, 4, 5], 3) == [3, 4, 5]


def test_negatives_only():
    assert sliding_window_max([-5, -3, -8, -1, -4], 2) == [-3, -3, -1, -1]


def test_k_equals_2():
    assert sliding_window_max([3, 1, 4, 1, 5, 9, 2, 6], 2) == [3, 4, 4, 5, 9, 9, 6]


def test_max_stays_in_window_longer():
    # 10 dominates windows 0-2, then exits; 8 dominates briefly; 9 dominates end
    assert sliding_window_max([10, 1, 1, 8, 1, 9], 3) == [10, 8, 8, 9]


def test_returns_list():
    result = sliding_window_max([1, 2, 3], 2)
    assert isinstance(result, list), "return type must be list"


def test_large_random_correctness():
    random.seed(1337)
    nums = [random.randint(-10000, 10000) for _ in range(10000)]
    k = 137
    assert sliding_window_max(nums, k) == _oracle(nums, k)


def test_output_length():
    nums = list(range(20))
    k = 5
    result = sliding_window_max(nums, k)
    assert len(result) == len(nums) - k + 1, \
        f"expected {len(nums)-k+1} elements, got {len(result)}"
PYEOF

if $PYTEST "_verify/test_hidden.py" -q 2>&1; then
    rm -rf "_verify"
    echo
    echo "All tests passed. Submit this flag in the platform:"
    echo
    echo "    $FLAG"
else
    rm -rf "_verify"
    fail "test suite has failures — fix your implementation and retry"
fi
