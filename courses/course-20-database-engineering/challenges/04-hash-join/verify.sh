#!/usr/bin/env bash
# Verifier for "Hash Join".
# Writes a hidden pytest suite, runs it against solution.py, and prints the
# flag only when every test passes.
# Exit 0 = solved, 1 = not yet.
set -uo pipefail

SLUG="04-hash-join"
WORK="$HOME/.kube-dojo-work/$SLUG"
FLAG='KUBE{hash_join_build_probe}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ]              || fail "work directory missing — run setup.sh first"
[ -f "$WORK/solution.py" ]  || fail "solution.py not found — run setup.sh first"

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
import sys, os, random, json
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from solution import hash_join


def _ref_join(left, right, lk, rk):
    """Reference nested-loop join used as oracle."""
    result = []
    for l in left:
        for r in right:
            if l[lk] == r[rk]:
                result.append({**l, **r})
    return result


def _norm(rows):
    """Sort rows into a canonical form for order-independent comparison."""
    return sorted(json.dumps(r, sort_keys=True) for r in rows)


def test_basic_join():
    left  = [{'l_id': 1, 'name': 'alice'}, {'l_id': 2, 'name': 'bob'}, {'l_id': 3, 'name': 'carol'}]
    right = [{'r_id': 1, 'score': 90}, {'r_id': 2, 'score': 75}]
    got = hash_join(left, right, 'l_id', 'r_id')
    exp = _ref_join(left, right, 'l_id', 'r_id')
    assert _norm(got) == _norm(exp), f"basic join mismatch: got {got}"


def test_no_matches():
    left  = [{'id': 1, 'v': 'a'}, {'id': 2, 'v': 'b'}]
    right = [{'id': 3, 'v': 'c'}, {'id': 4, 'v': 'd'}]
    got = hash_join(left, right, 'id', 'id')
    assert got == [], f"no matches: expected [], got {got}"


def test_many_to_many_duplicates():
    left  = [{'k': 1, 'lv': 'A'}, {'k': 1, 'lv': 'B'}]
    right = [{'k': 1, 'rv': 'X'}, {'k': 1, 'rv': 'Y'}, {'k': 1, 'rv': 'Z'}]
    got = hash_join(left, right, 'k', 'k')
    exp = _ref_join(left, right, 'k', 'k')
    assert len(got) == 6, f"many-to-many: expected 6 rows, got {len(got)}"
    assert _norm(got) == _norm(exp)


def test_empty_left():
    got = hash_join([], [{'id': 1, 'v': 'x'}], 'id', 'id')
    assert got == [], f"empty left: expected [], got {got}"


def test_empty_right():
    got = hash_join([{'id': 1, 'v': 'x'}], [], 'id', 'id')
    assert got == [], f"empty right: expected [], got {got}"


def test_both_empty():
    got = hash_join([], [], 'id', 'id')
    assert got == [], f"both empty: expected [], got {got}"


def test_all_rows_match():
    left  = [{'a': i, 'lv': i * 2} for i in range(1, 6)]
    right = [{'b': i, 'rv': i * 3} for i in range(1, 6)]
    got = hash_join(left, right, 'a', 'b')
    exp = _ref_join(left, right, 'a', 'b')
    assert len(got) == 5
    assert _norm(got) == _norm(exp)


def test_right_larger_build_on_left():
    # right has 1000 rows, left has 5 — correct impl builds on left (smaller)
    left = [{'dept': i, 'dname': f'd{i}'} for i in range(5)]
    random.seed(2024)
    right = [{'dept': random.randint(0, 4), 'emp': f'emp{j}'} for j in range(1000)]
    got = hash_join(left, right, 'dept', 'dept')
    exp = _ref_join(left, right, 'dept', 'dept')
    assert _norm(got) == _norm(exp), "right-larger dataset mismatch"


def test_left_larger_build_on_right():
    # left has 1000 rows, right has 5 — correct impl builds on right (smaller)
    random.seed(2025)
    left  = [{'dept': random.randint(0, 4), 'emp': f'emp{j}'} for j in range(1000)]
    right = [{'dept': i, 'dname': f'd{i}'} for i in range(5)]
    got = hash_join(left, right, 'dept', 'dept')
    exp = _ref_join(left, right, 'dept', 'dept')
    assert _norm(got) == _norm(exp), "left-larger dataset mismatch"


def test_string_join_keys():
    left  = [{'cat': 'fruit', 'item': 'apple'}, {'cat': 'veggie', 'item': 'carrot'}]
    right = [{'category': 'fruit', 'color': 'red'}, {'category': 'fruit', 'color': 'green'}]
    got = hash_join(left, right, 'cat', 'category')
    exp = _ref_join(left, right, 'cat', 'category')
    assert len(got) == 2
    assert _norm(got) == _norm(exp), "string-key join mismatch"


def test_returns_list():
    result = hash_join([{'id': 1, 'v': 'a'}], [{'id': 1, 'w': 'b'}], 'id', 'id')
    assert isinstance(result, list), "return type must be list"


def test_large_random_correctness():
    random.seed(1337)
    left  = [{'k': random.randint(0, 99), 'lv': i} for i in range(500)]
    right = [{'k': random.randint(0, 99), 'rv': i} for i in range(500)]
    got = hash_join(left, right, 'k', 'k')
    exp = _ref_join(left, right, 'k', 'k')
    assert _norm(got) == _norm(exp), f"large random: expected {len(exp)} rows, got {len(got)}"


def test_mixed_duplicate_and_unique_keys():
    # Some keys have duplicates on left, some on right, some on both, some only on one side
    left  = [
        {'id': 1, 'side': 'L1'}, {'id': 1, 'side': 'L2'},
        {'id': 2, 'side': 'L3'},
        {'id': 3, 'side': 'L4'},
    ]
    right = [
        {'id': 1, 'side': 'R1'},
        {'id': 2, 'side': 'R2'}, {'id': 2, 'side': 'R3'},
        {'id': 4, 'side': 'R4'},
    ]
    # id=1: 2L × 1R = 2; id=2: 1L × 2R = 2; id=3: 0R; id=4: 0L → total 4
    got = hash_join(left, right, 'id', 'id')
    exp = _ref_join(left, right, 'id', 'id')
    assert len(got) == 4, f"mixed duplicates: expected 4 rows, got {len(got)}"
    assert _norm(got) == _norm(exp)
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
