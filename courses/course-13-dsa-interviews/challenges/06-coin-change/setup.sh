#!/usr/bin/env bash
# Plants the "Coin Change" starter project.
# Idempotent — re-running overwrites source files but does not delete .venv.
set -euo pipefail

SLUG="06-coin-change"
WORK="$HOME/.kube-dojo-work/$SLUG"
mkdir -p "$WORK/tests"

# ── solution.py skeleton ─────────────────────────────────────────────────────
cat > "$WORK/solution.py" << 'PYEOF'
# solution.py — Coin Change
# Implement coin_change(coins, amount).
# Return the fewest coins needed to make exactly `amount`,
# or -1 if it is impossible.
#
# Recommended approach: bottom-up DP
#
#   dp[i] = minimum coins needed to make amount i
#   dp[0] = 0          (zero coins for zero amount)
#   dp[i] = inf        (sentinel: not yet reachable)
#
#   For each amount i from 1..amount:
#     For each coin c in coins:
#       if c <= i and dp[i - c] + 1 < dp[i]:
#         dp[i] = dp[i - c] + 1
#
#   Return dp[amount] if it is not inf, else -1.
#
# Alternative: top-down DFS with memoisation — also accepted.

from typing import List


def coin_change(coins: List[int], amount: int) -> int:
    # TODO: implement
    raise NotImplementedError("implement coin_change")
PYEOF

# ── tests/test_coins.py (visible harness) ────────────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

cat > "$WORK/tests/test_coins.py" << 'PYEOF'
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from solution import coin_change


def test_example_1():
    # 1+5+5+5 = 3 coins; greedy (11+1+1+1+1) uses 5
    assert coin_change([1, 5, 11], 15) == 3

def test_example_2():
    assert coin_change([2], 3) == -1

def test_zero_amount():
    assert coin_change([1, 2, 5], 0) == 0

def test_exact_single_coin():
    assert coin_change([1, 5, 11], 11) == 1

def test_classic():
    # standard leetcode example: [1,2,5], amount=11 → 3 (5+5+1)
    assert coin_change([1, 2, 5], 11) == 3
PYEOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : implement coin_change(coins, amount) in solution.py."
echo "                 Use bottom-up DP (see the docstring sketch) or top-down"
echo "                 with memoisation. Greedy will NOT pass the hidden tests."
echo
echo "Prerequisites  :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate"
echo "  pip install pytest"
echo
echo "Run tests      : cd $WORK && .venv/bin/pytest tests/ -v"
echo "Verify + flag  : bash courses/course-13-dsa-interviews/challenges/$SLUG/verify.sh"
