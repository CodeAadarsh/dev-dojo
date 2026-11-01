#!/usr/bin/env bash
# Verifier for "Longest Increasing Path in a Matrix".
# Writes a hidden pytest suite, runs it against solution.py, and prints the
# flag only when every test passes.
# Exit 0 = solved, 1 = not yet.
set -uo pipefail

SLUG="02-coding-drill-graphs-or-dp"
WORK="$HOME/.kube-dojo-work/$SLUG"
FLAG='KUBE{longest_increasing_path_dfs_memo}'

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
from solution import longest_increasing_path


def _oracle(matrix):
    if not matrix or not matrix[0]:
        return 0
    m, n = len(matrix), len(matrix[0])
    memo = [[0] * n for _ in range(m)]
    dirs = [(0, 1), (0, -1), (1, 0), (-1, 0)]

    def dfs(r, c):
        if memo[r][c]:
            return memo[r][c]
        best = 1
        for dr, dc in dirs:
            nr, nc = r + dr, c + dc
            if 0 <= nr < m and 0 <= nc < n and matrix[nr][nc] > matrix[r][c]:
                best = max(best, 1 + dfs(nr, nc))
        memo[r][c] = best
        return best

    sys.setrecursionlimit(m * n + 10)
    return max(dfs(r, c) for r in range(m) for c in range(n))


def test_example_a():
    matrix = [[9, 9, 4], [6, 6, 8], [2, 1, 1]]
    assert longest_increasing_path(matrix) == 4


def test_example_b():
    matrix = [[1, 2, 3], [6, 5, 4]]
    assert longest_increasing_path(matrix) == 6


def test_single_cell():
    assert longest_increasing_path([[42]]) == 1


def test_all_equal():
    assert longest_increasing_path([[5, 5], [5, 5]]) == 1


def test_strictly_increasing_row():
    # 1 -> 2 -> 3 -> 4 -> 5 = 5
    assert longest_increasing_path([[1, 2, 3, 4, 5]]) == 5


def test_strictly_decreasing_column():
    # Best path: 1 -> 2 -> 3 -> 4 going upward
    matrix = [[4], [3], [2], [1]]
    assert longest_increasing_path(matrix) == 4


def test_snake_path():
    # Spiral increasing path of length 9
    matrix = [
        [1, 2, 3],
        [6, 5, 4],
        [7, 8, 9],
    ]
    assert longest_increasing_path(matrix) == 9


def test_equal_adjacent_not_counted():
    # Adjacent equal values must NOT extend the path
    matrix = [[1, 1, 2]]
    # path: 1 -> 2 (length 2); the two 1s can't chain because 1 is not > 1
    assert longest_increasing_path(matrix) == 2


def test_two_cells_increasing():
    assert longest_increasing_path([[1, 2]]) == 2


def test_two_cells_decreasing():
    # From cell 0: 2 -> can't go right (1 < 2), path = 1
    # From cell 1: 1 -> can't go anywhere, path = 1
    # Best = 1... wait: we CAN go left from cell 1 to cell 0 since 2 > 1
    # So path 1 -> 2 from the right cell gives length 2
    assert longest_increasing_path([[2, 1]]) == 2


def test_large_matrix():
    random.seed(7)
    m, n = 30, 30
    matrix = [[random.randint(0, 1000) for _ in range(n)] for _ in range(m)]
    result = longest_increasing_path(matrix)
    expected = _oracle(matrix)
    assert result == expected, f"got {result}, expected {expected}"


def test_returns_int():
    result = longest_increasing_path([[1, 2], [3, 4]])
    assert isinstance(result, int), "return type must be int"
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
