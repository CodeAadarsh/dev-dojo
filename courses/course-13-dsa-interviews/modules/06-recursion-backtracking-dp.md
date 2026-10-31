# Recursion, Backtracking & Dynamic Programming

> **Module 06 · Course 13** — DP is the problem type most candidates say they "know" and most candidates fail under time pressure. The failure isn't missing the algorithm — it's not having a repeatable framework for deriving the state space before touching the keyboard. This module gives you that framework.

---

## The Pipeline: Recursion → Memoization → Tabulation

Every DP solution passes through the same three stages. Work the stages in order — never jump to tabulation.

### Stage 1: Recursive brute-force

Solve the problem by exploring all choices. No caching, no optimization. The goal is to get the recursion correct.

```python
# Example: count ways to climb n stairs (1 or 2 steps at a time)
def climb_brute(n: int) -> int:
    if n <= 1:
        return 1
    return climb_brute(n - 1) + climb_brute(n - 2)
```

This is O(2^n). It's correct. That matters more than it being fast.

### Stage 2: Memoization (top-down DP)

Add a cache. The recursion tree is the same; you just don't recompute branches you've already solved.

```python
from functools import lru_cache

@lru_cache(maxsize=None)
def climb_memo(n: int) -> int:
    if n <= 1:
        return 1
    return climb_memo(n - 1) + climb_memo(n - 2)
```

Or with an explicit dict for interviews where decorators feel wrong:

```python
def climb_memo_dict(n: int, memo: dict = {}) -> int:
    if n in memo:
        return memo[n]
    if n <= 1:
        return 1
    memo[n] = climb_memo_dict(n - 1, memo) + climb_memo_dict(n - 2, memo)
    return memo[n]
```

Memoization converts the recursion from O(2^n) to O(n) time and O(n) space. This is the first solution you should have running — then optimize.

### Stage 3: Tabulation (bottom-up DP)

Flip the direction: build from base cases up to the answer. No call stack, constant space possible when only the last k values matter.

```python
def climb_tab(n: int) -> int:
    if n <= 1:
        return 1
    dp = [0] * (n + 1)
    dp[0] = dp[1] = 1
    for i in range(2, n + 1):
        dp[i] = dp[i - 1] + dp[i - 2]
    return dp[n]

# Space-optimized: only need last two values
def climb_tab_opt(n: int) -> int:
    if n <= 1:
        return 1
    a, b = 1, 1
    for _ in range(2, n + 1):
        a, b = b, a + b
    return b
```

---

## The DP State/Transition Framework

Before writing a single line of DP code, answer these four questions:

1. **What is the state?** What information do I need to fully describe a subproblem? This is your `dp[...]` index set.
2. **What does `dp[i]` (or `dp[i][j]`) mean?** Write it in English. If you can't write it clearly, your state is wrong.
3. **What is the transition?** How do I compute `dp[i]` from smaller subproblems?
4. **What are the base cases?** The smallest subproblems you can answer without recursion.

If you can't answer all four before coding, you'll write the wrong DP and debug from a broken foundation.

---

## Classic DP Problems

### 0/1 Knapsack

```
State: dp[i][w] = max value using items 0..i with capacity w
Transition: dp[i][w] = max(dp[i-1][w],                     # skip item i
                            dp[i-1][w - weight[i]] + val[i]) # take item i (if w >= weight[i])
Base: dp[0][w] = val[0] if w >= weight[0] else 0
```

```python
def knapsack(weights: list, values: list, capacity: int) -> int:
    n = len(weights)
    dp = [[0] * (capacity + 1) for _ in range(n)]

    for w in range(weights[0], capacity + 1):
        dp[0][w] = values[0]

    for i in range(1, n):
        for w in range(capacity + 1):
            skip = dp[i - 1][w]
            take = dp[i - 1][w - weights[i]] + values[i] if w >= weights[i] else 0
            dp[i][w] = max(skip, take)

    return dp[n - 1][capacity]
```

Space optimize to O(capacity) by using a 1D `dp` array and iterating `w` from high to low (right to left) so that `dp[w - weight[i]]` still represents the i-1 state when you access it.

### Longest Increasing Subsequence (LIS)

```
State: dp[i] = length of LIS ending at index i
Transition: dp[i] = 1 + max(dp[j] for j < i if nums[j] < nums[i])
Base: dp[i] = 1 for all i
```

```python
def length_of_lis(nums: list[int]) -> int:
    n = len(nums)
    dp = [1] * n
    for i in range(1, n):
        for j in range(i):
            if nums[j] < nums[i]:
                dp[i] = max(dp[i], dp[j] + 1)
    return max(dp)
```

This is O(n²). The O(n log n) version uses patience sorting (binary search on a `tails` array). Know the O(n²) version first; the interviewer will ask for the optimization.

```python
import bisect

def length_of_lis_nlogn(nums: list[int]) -> int:
    tails: list[int] = []
    for num in nums:
        pos = bisect.bisect_left(tails, num)
        if pos == len(tails):
            tails.append(num)
        else:
            tails[pos] = num
    return len(tails)
```

`tails[i]` is the smallest tail element of all increasing subsequences of length `i+1`. It's not a valid LIS, but its length equals the LIS length.

### Edit Distance (Levenshtein)

```
State: dp[i][j] = min edits to convert word1[:i] to word2[:j]
Transition:
  if word1[i-1] == word2[j-1]: dp[i][j] = dp[i-1][j-1]          # no edit needed
  else: dp[i][j] = 1 + min(dp[i-1][j],    # delete from word1
                            dp[i][j-1],    # insert into word1
                            dp[i-1][j-1])  # replace
Base: dp[i][0] = i (delete all chars), dp[0][j] = j (insert all chars)
```

```python
def edit_distance(word1: str, word2: str) -> int:
    m, n = len(word1), len(word2)
    dp = [[0] * (n + 1) for _ in range(m + 1)]

    for i in range(m + 1):
        dp[i][0] = i
    for j in range(n + 1):
        dp[0][j] = j

    for i in range(1, m + 1):
        for j in range(1, n + 1):
            if word1[i - 1] == word2[j - 1]:
                dp[i][j] = dp[i - 1][j - 1]
            else:
                dp[i][j] = 1 + min(dp[i - 1][j],
                                    dp[i][j - 1],
                                    dp[i - 1][j - 1])

    return dp[m][n]
```

The three operations map directly to three neighboring cells. Draw the table for `word1="horse", word2="ros"` once — every cell's value becomes obvious.

---

## Backtracking

Backtracking is DFS on an implicit state space. The template:

```python
def backtrack(state, choices, result):
    if is_complete(state):
        result.append(copy_of(state))
        return
    for choice in choices:
        if is_valid(choice, state):
            apply(choice, state)
            backtrack(state, updated_choices, result)
            undo(choice, state)         # MUST undo — this is the "back" in backtracking
```

The `undo` step is what separates backtracking from plain DFS. If you forget to undo, the state from one branch leaks into sibling branches.

### Subsets

```python
def subsets(nums: list[int]) -> list[list[int]]:
    result, current = [], []

    def backtrack(start: int) -> None:
        result.append(current[:])       # snapshot before recursing
        for i in range(start, len(nums)):
            current.append(nums[i])
            backtrack(i + 1)
            current.pop()               # undo

    backtrack(0)
    return result
```

### Permutations

```python
def permutations(nums: list[int]) -> list[list[int]]:
    result, current, used = [], [], [False] * len(nums)

    def backtrack() -> None:
        if len(current) == len(nums):
            result.append(current[:])
            return
        for i in range(len(nums)):
            if used[i]:
                continue
            used[i] = True
            current.append(nums[i])
            backtrack()
            current.pop()
            used[i] = False             # undo both state mutations

    backtrack()
    return result
```

### N-Queens

```python
def solve_n_queens(n: int) -> list[list[str]]:
    result = []
    cols    = set()
    diag1   = set()   # row - col = const for same '\' diagonal
    diag2   = set()   # row + col = const for same '/' diagonal

    board = [['.' ] * n for _ in range(n)]

    def backtrack(row: int) -> None:
        if row == n:
            result.append([''.join(r) for r in board])
            return
        for col in range(n):
            if col in cols or (row - col) in diag1 or (row + col) in diag2:
                continue
            cols.add(col)
            diag1.add(row - col)
            diag2.add(row + col)
            board[row][col] = 'Q'

            backtrack(row + 1)

            cols.remove(col)
            diag1.remove(row - col)
            diag2.remove(row + col)
            board[row][col] = '.'   # undo

    backtrack(0)
    return result
```

The diagonal encoding (`row - col` for one diagonal, `row + col` for the other) is worth memorizing — it lets you check all three constraints in O(1) per cell using sets.

---

## Pruning — Making Backtracking Fast

Backtracking without pruning is brute-force. Pruning is the difference between TLE and AC:

- **Sort first** when you need to skip duplicates (subsets/permutations with duplicate elements: `if i > start and nums[i] == nums[i-1]: continue`).
- **Early termination**: return from the recursive call as soon as a constraint is violated, not after exhausting all children.
- **Constraint propagation**: in N-Queens, maintaining `cols`, `diag1`, `diag2` as sets makes each constraint check O(1) instead of O(n).

---

## Common Mistakes

| Symptom | Cause | Fix |
|---------|-------|-----|
| DP gives wrong answer despite correct logic | Wrong state definition — `dp[i]` means something inconsistent | Write the English definition of `dp[i]` before touching code; if it's ambiguous, the state is wrong |
| Memoization cache grows stale across test calls | Using a mutable default dict argument across calls | Pass `memo=None` and initialize inside the function, or use `@lru_cache` with a clear call between tests |
| Backtracking produces duplicate subsets | Not skipping duplicate elements after sorting | Add `if i > start and nums[i] == nums[i-1]: continue` after sorting |
| State leaks between backtracking branches | Forgetting to undo a mutation | Every `apply(choice, state)` must have a matching `undo(choice, state)` before the loop iteration ends |
| Tabulation out-of-bounds | Loop bounds not accounting for 1-indexed `dp` arrays | When `dp[i]` represents `nums[:i]`, the array is size `n+1` and inner loop starts at `1`, not `0` |
| LIS O(n²) is too slow, but O(n log n) solution is wrong | `tails` array is treated as the actual LIS | `tails` is not a valid LIS; only its length is the answer — never return `tails` directly |
| Recursion stack overflow on deep DP | Using memoization on a problem with O(n) call depth and Python's 1000-limit | Convert to tabulation (bottom-up) for large n; or `sys.setrecursionlimit` only in contest |

> **War story.** A Google SWE-3 friend described an intern who solved "word break" in an on-site perfectly — got the recursion right, added memoization, explained the O(n² × L) complexity correctly. Then the interviewer asked: "what if I call your function 100,000 times in a loop?" The function used a mutable default argument `memo={}` — so the cache from call 1 polluted call 2. The intern's tests all passed (same input), but a multi-call scenario gave wrong cached results. The fix is one line: `memo = {}` inside the function body, or `@lru_cache` at the module level. The deeper point: DP functions must have clean state boundaries. At SAP, I've seen the same bug in production Python workers that process user-specific data with a module-level cache — the cache key included the user ID, but a missed edge case let two users share an entry. The function looked correct in unit tests (one user per test) and broke silently in production under concurrent load.

---

## Checkpoint

You're ready for the challenges when you can, without hints:

1. Take a recursive brute-force solution and mechanically convert it to memoization, then to tabulation — without changing the state definition.
2. Write out the four DP framework questions (state, meaning, transition, base cases) for edit distance before writing a single line of code.
3. Implement the knapsack DP and then space-optimize it to O(capacity) — explain why iterating `w` from right to left is required.
4. Implement the backtracking template for subsets; then extend it to handle duplicates by sorting + skipping.
5. Implement N-Queens and explain the `row - col` / `row + col` diagonal encoding.
6. State the difference between memoization and tabulation in terms of call order, stack usage, and which one you'd choose for a problem where not all subproblems need to be solved.

➡ You've completed the core algorithmic patterns. The remaining modules focus on system-design-adjacent topics (concurrency, distributed primitives) that appear in SDE-2 and SRE-2 rounds.
