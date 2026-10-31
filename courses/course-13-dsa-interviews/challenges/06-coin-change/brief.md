# Coin Change

A billing engineer sends this Slack message at 11pm: *"Our rounding logic is broken — it greedily picks the largest denomination and sometimes overshoots. We need the actual minimum number of transactions to hit the exact target."*

Greedy works for some coin systems (e.g. the real US mint), but not for arbitrary denomination sets. The only correct general solution is dynamic programming — and it's the canonical unbounded knapsack problem that every panel will eventually ask about.

## Mission

Implement `coin_change(coins, amount)` in `solution.py`.

```
coin_change([1, 5, 11], 15)    →  3   (11 + 3×1 uses 4; 5+5+5 uses 3)
coin_change([1, 5, 11], 11)    →  1   (one 11-coin)
coin_change([2], 3)            → -1   (can't make 3 with only 2-coins)
coin_change([1], 0)            →  0   (amount is 0, zero coins needed)
```

**Constraints**

- 1 ≤ `len(coins)` ≤ 12
- 1 ≤ `coins[i]` ≤ 2,000 (coins are distinct positive integers)
- 0 ≤ `amount` ≤ 10,000
- Return the minimum number of coins, or `-1` if the amount cannot be made

## Setup

```bash
bash courses/course-13-dsa-interviews/challenges/06-coin-change/setup.sh
```

## Verify

```bash
bash courses/course-13-dsa-interviews/challenges/06-coin-change/verify.sh
```

All tests green → flag printed.

## Why greedy fails here

With coins `[1, 5, 11]` and amount `15`:
- Greedy picks 11 first → remaining 4 → picks 1×4 → **5 coins total**
- Optimal is 5+5+5 → **3 coins**

Greedy only works when the coin system has the "greedy property" (each denomination is a multiple of the next smaller, roughly). Arbitrary denominations break this — you must solve every sub-problem.

## Why this matters

The bottom-up DP pattern here — build a table of optimal sub-problem solutions, fill it in dependency order, return `dp[amount]` — is the same skeleton that solves:
- **Unbounded knapsack**: how many items of unlimited supply fit a weight budget optimally?
- **Jump game / climbing stairs**: minimum moves to reach position N
- **Word break**: can a string be segmented into dictionary words?
- **Edit distance**: fewest single-character edits to transform one string to another

Recognising the "unbounded sub-problem: optimal sub-amount leads to optimal full amount" structure is what separates candidates who score Hard DPs from those who stall on them.
