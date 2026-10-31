# Solution — Coin Change

## Bottom-up DP

```python
from typing import List

def coin_change(coins: List[int], amount: int) -> int:
    dp = [float('inf')] * (amount + 1)
    dp[0] = 0

    for i in range(1, amount + 1):
        for c in coins:
            if c <= i and dp[i - c] + 1 < dp[i]:
                dp[i] = dp[i - c] + 1

    return dp[amount] if dp[amount] != float('inf') else -1
```

### Why this works

**State definition:** `dp[i]` = minimum number of coins to make exactly amount `i`.

**Base case:** `dp[0] = 0`. Zero coins are needed to make zero.

**Transition:** to make amount `i`, try each coin `c`. If `c <= i` and we already know the optimal for `i - c`, then using coin `c` once on top of that gives us `dp[i - c] + 1` coins total. We take the minimum over all valid coins.

**Sentinel:** `float('inf')` marks amounts that are currently unreachable. If `dp[amount]` is still `inf` at the end, no combination of coins can make the amount exactly — return `-1`.

**Order independence:** because we iterate `i` from 0 to `amount`, `dp[i - c]` is always computed before `dp[i]` (since `c >= 1`). No two-pass trick needed.

### Complexity

| | |
|---|---|
| **Time** | O(amount × len(coins)) |
| **Space** | O(amount) for the dp array |

For the given constraints (amount ≤ 10,000, coins ≤ 12), this is at most 120,000 operations.

## Why greedy fails

Greedy: always pick the largest coin that fits. Optimal sub-structure doesn't hold for arbitrary coin sets.

Counterexample — coins `[1, 3, 4]`, amount `6`:
- Greedy: pick 4 → remaining 2 → pick 1+1 → **3 coins**
- Optimal: pick 3+3 → **2 coins**

The DP explores every denomination for every sub-amount and takes the true minimum.

## Top-down alternative (memoised recursion)

```python
from typing import List
from functools import lru_cache

def coin_change(coins: List[int], amount: int) -> int:
    @lru_cache(maxsize=None)
    def dp(remaining: int) -> int:
        if remaining == 0:
            return 0
        if remaining < 0:
            return float('inf')
        return min(dp(remaining - c) + 1 for c in coins)

    result = dp(amount)
    return result if result != float('inf') else -1
```

Same O(amount × coins) complexity. The bottom-up version is preferred in production (no recursion overhead, no stack limit risk), but top-down is easier to derive at a whiteboard from the recurrence.

## Apply and verify

```bash
cd ~/.kube-dojo-work/06-coin-change
# paste the bottom-up solution into solution.py, then:
.venv/bin/pytest tests/ -v
bash courses/course-13-dsa-interviews/challenges/06-coin-change/verify.sh
```
