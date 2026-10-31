#!/usr/bin/env bash
# Verifier for "Coin Change".
# Writes a hidden pytest suite at runtime, runs it against solution.py,
# prints the flag only when every test passes.
set -uo pipefail

SLUG="06-coin-change"
WORK="$HOME/.kube-dojo-work/$SLUG"
FLAG='KUBE{dp_solves_coin_change}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ] || fail "work directory missing — run setup.sh first"
[ -f "$WORK/solution.py" ] || fail "solution.py not found in $WORK — run setup.sh first"

cd "$WORK"

if [ -f ".venv/bin/pytest" ]; then
    PYTEST=".venv/bin/pytest"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
else
    fail "pytest not found — activate the venv: cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install pytest"
fi

HIDDEN_DIR="$WORK/.hidden_tests"
mkdir -p "$HIDDEN_DIR"

cat > "$HIDDEN_DIR/__init__.py" << 'PYEOF'
PYEOF

cat > "$HIDDEN_DIR/test_coins_hidden.py" << 'PYEOF'
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from solution import coin_change


# ── zero / trivial ────────────────────────────────────────────────────────────

def test_zero_amount():
    assert coin_change([1], 0) == 0

def test_zero_amount_multiple_coins():
    assert coin_change([1, 5, 10], 0) == 0

def test_impossible_single_coin():
    assert coin_change([2], 3) == -1

def test_impossible_no_divisor():
    assert coin_change([5, 10], 3) == -1

def test_impossible_large():
    assert coin_change([3, 7], 11) == -1   # 3a+7b=11 → no non-neg solution

# ── exact single coin ─────────────────────────────────────────────────────────

def test_exact_match():
    assert coin_change([1, 5, 11], 11) == 1

def test_exact_match_large_denom():
    assert coin_change([100], 100) == 1

# ── greedy fails here (canary tests) ─────────────────────────────────────────

def test_greedy_fails_1():
    # greedy: 11+1+1+1+1 = 5; optimal: 5+5+5 = 3
    assert coin_change([1, 5, 11], 15) == 3

def test_greedy_fails_2():
    # coins [1, 3, 4], amount 6: greedy 4+1+1=3; optimal 3+3=2
    assert coin_change([1, 3, 4], 6) == 2

def test_greedy_fails_3():
    # coins [1, 7, 10], amount 14: greedy 10+1+1+1+1=5; optimal 7+7=2
    assert coin_change([1, 7, 10], 14) == 2

# ── classic examples ──────────────────────────────────────────────────────────

def test_classic_leetcode():
    assert coin_change([1, 2, 5], 11) == 3

def test_single_denomination_divisible():
    assert coin_change([3], 9) == 3

def test_single_denomination_not_divisible():
    assert coin_change([3], 10) == -1

# ── large amount ─────────────────────────────────────────────────────────────

def test_large_amount_feasible():
    # 10000 / 5 = 2000 coins
    assert coin_change([1, 5, 10, 25], 10000) == 400  # 10000/25 = 400

def test_large_amount_single_denom():
    assert coin_change([1], 9999) == 9999

def test_large_impossible():
    # gcd(6,9,20)=1 but 11 cannot be formed: no combo of 6,9,20 sums to 11
    assert coin_change([6, 9, 20], 11) == -1

# ── boundary: amount equals one coin ─────────────────────────────────────────

def test_amount_equals_coin():
    assert coin_change([2, 5, 10], 5) == 1

def test_amount_less_than_all_coins():
    assert coin_change([5, 10, 25], 3) == -1

# ── return type ───────────────────────────────────────────────────────────────

def test_return_type_positive():
    result = coin_change([1, 2, 5], 11)
    assert isinstance(result, int), f"expected int, got {type(result)}"
    assert result == 3

def test_return_type_impossible():
    result = coin_change([2], 3)
    assert isinstance(result, int), f"expected int, got {type(result)}"
    assert result == -1
PYEOF

if $PYTEST "$HIDDEN_DIR/" -q 2>&1; then
    echo
    echo "All tests passed. Submit this flag in the platform:"
    echo
    echo "    $FLAG"
else
    fail "test suite has failures — fix your implementation in $WORK/solution.py and retry"
fi
