#!/usr/bin/env bash
# Verifier for "Top K Frequent Elements".
# Writes a hidden pytest suite, runs it against solution.py, and prints the
# flag only when every test passes.
# Exit 0 = solved, 1 = not yet.
set -uo pipefail

SLUG="03-top-k-frequent"
WORK="$HOME/.kube-dojo-work/$SLUG"
FLAG='KUBE{top_k_frequent_bucket_sort}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ]             || fail "work directory missing — run setup.sh first"
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
from collections import Counter
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from solution import top_k_frequent


def _oracle(nums, k):
    counts = Counter(nums)
    return sorted(counts, key=lambda x: -counts[x])[:k]


def _check(nums, k):
    result = top_k_frequent(nums, k)
    assert isinstance(result, list), "return type must be list"
    assert len(result) == k, f"expected {k} elements, got {len(result)}"
    expected = set(_oracle(nums, k))
    assert set(result) == expected, \
        f"expected elements {sorted(expected)}, got {sorted(result)}"


def test_example_k2():
    _check([1, 1, 1, 2, 2, 3], 2)


def test_single_element():
    _check([1], 1)


def test_k_equals_distinct():
    _check([3, 1, 4, 1, 5, 9, 2, 6, 5, 3, 5], 5)


def test_all_same():
    _check([7, 7, 7, 7], 1)


def test_k1_picks_most_frequent():
    result = top_k_frequent([3, 3, 3, 1, 1, 2], 1)
    assert result == [3] or result == [3]   # 3 appears 3 times


def test_negative_values():
    _check([-1, -1, -2, -2, -2, 3], 2)


def test_large_k():
    nums = [1]*5 + [2]*4 + [3]*3 + [4]*2 + [5]*1
    _check(nums, 4)


def test_all_unique_frequencies():
    # each element has a unique frequency; no ambiguity
    nums = [1]*10 + [2]*7 + [3]*5 + [4]*3 + [5]*1
    _check(nums, 3)


def test_returns_list_not_set():
    result = top_k_frequent([1, 1, 2], 1)
    assert isinstance(result, list), "must return a list, not a set or other type"


def test_large_random():
    random.seed(7)
    # 100 distinct values with 100k total elements, no tie at boundary
    vals = list(range(100))
    freqs = list(range(1, 101))   # unique frequencies 1..100
    nums = []
    for v, f in zip(vals, freqs):
        nums.extend([v] * f)
    random.shuffle(nums)
    k = 10
    _check(nums, k)


def test_two_elements_k1():
    _check([1, 1, 2], 1)


def test_order_does_not_matter():
    # verifier accepts any permutation
    result = top_k_frequent([1, 1, 1, 2, 2, 3], 2)
    assert set(result) == {1, 2}
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
