#!/usr/bin/env bash
# Verifier for "Merge Intervals".
# Writes a hidden pytest suite, runs it against solution.py, and prints the
# flag only when every test passes.
# Exit 0 = solved, 1 = not yet.
set -uo pipefail

SLUG="01-coding-drill-arrays"
WORK="$HOME/.kube-dojo-work/$SLUG"
FLAG='KUBE{merge_intervals_sorted_sweep}'

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
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from solution import merge_intervals


def _oracle(intervals):
    if not intervals:
        return []
    sorted_ivs = sorted(intervals, key=lambda x: x[0])
    merged = [sorted_ivs[0][:]]
    for start, end in sorted_ivs[1:]:
        if start <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], end)
        else:
            merged.append([start, end])
    return merged


def test_basic_overlap():
    assert merge_intervals([[1, 3], [2, 6], [8, 10], [15, 18]]) == [[1, 6], [8, 10], [15, 18]]


def test_touching_boundary():
    assert merge_intervals([[1, 4], [4, 5]]) == [[1, 5]]


def test_single_interval():
    assert merge_intervals([[3, 7]]) == [[3, 7]]


def test_all_overlapping():
    assert merge_intervals([[1, 10], [2, 6], [3, 8]]) == [[1, 10]]


def test_unsorted_input():
    assert merge_intervals([[1, 4], [0, 4]]) == [[0, 4]]


def test_unsorted_complex():
    assert merge_intervals([[1, 4], [0, 2], [3, 5]]) == [[0, 5]]


def test_no_overlap():
    assert merge_intervals([[1, 2], [3, 4], [5, 6]]) == [[1, 2], [3, 4], [5, 6]]


def test_adjacent_not_overlapping():
    # [1,2] and [3,4] do not share an endpoint — should NOT merge
    result = merge_intervals([[1, 2], [3, 4]])
    assert result == [[1, 2], [3, 4]]


def test_contained_interval():
    # [1,10] contains [2,5] entirely
    assert merge_intervals([[1, 10], [2, 5]]) == [[1, 10]]


def test_multiple_merges():
    # Chain: 1-3 + 2-5 + 4-8 + 9-11 = [1,8],[9,11]
    assert merge_intervals([[1, 3], [2, 5], [4, 8], [9, 11]]) == [[1, 8], [9, 11]]


def test_returns_list_of_lists():
    result = merge_intervals([[1, 2]])
    assert isinstance(result, list), "return type must be list"
    assert isinstance(result[0], list), "each element must be a list"


def test_large_random():
    random.seed(42)
    intervals = [[random.randint(0, 500), 0] for _ in range(500)]
    for iv in intervals:
        iv[1] = iv[0] + random.randint(0, 50)
    assert merge_intervals(intervals) == _oracle(intervals)


def test_output_sorted_by_start():
    result = merge_intervals([[5, 6], [1, 2], [3, 4]])
    assert result == sorted(result, key=lambda x: x[0]), "output must be sorted by start"
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
