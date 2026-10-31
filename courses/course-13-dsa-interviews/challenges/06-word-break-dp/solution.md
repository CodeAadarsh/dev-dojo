# Solution — Word Break

The flag is `KUBE{memoize_then_tabulate}`.

## Top-down (memoization)

```python
def word_break_memo(s: str, word_dict: list) -> bool:
    words = set(word_dict)
    memo: dict[int, bool] = {}

    def dp(i: int) -> bool:
        if i == len(s):
            return True
        if i in memo:
            return memo[i]
        for j in range(i + 1, len(s) + 1):
            if s[i:j] in words and dp(j):
                memo[i] = True
                return True
        memo[i] = False
        return False

    return dp(0)
```

State: `dp(i)` = can `s[i:]` be segmented?
Transition: try every split point `j > i`; if `s[i:j]` is a word and `dp(j)` is True, then `dp(i)` is True.
Base: `dp(len(s)) = True` (empty suffix is always segmentable).

The `memo` dict is local to the function — no state leaks between calls.

## Bottom-up (tabulation)

```python
def word_break_tab(s: str, word_dict: list) -> bool:
    words = set(word_dict)
    n = len(s)
    dp = [False] * (n + 1)
    dp[0] = True        # empty prefix is always segmentable

    for i in range(1, n + 1):
        for j in range(i):
            if dp[j] and s[j:i] in words:
                dp[i] = True
                break

    return dp[n]
```

State: `dp[i]` = can `s[:i]` be segmented?
Transition: `dp[i]` is True if there exists a `j < i` such that `dp[j]` is True and `s[j:i]` is a word.
Base: `dp[0] = True`.

## Why the adversarial test matters

`s = "aaa...ab"` (30 a's then b) with `word_dict = ["a", "aa", ..., "aaaaaaaaa"]` has no valid segmentation (the `b` can never be matched). Naive recursion without memoization explores all 2^30 combinations of a-prefixes before concluding False. With memoization, each index 0..31 is computed exactly once — O(n² × L) total where L is the average word length.

## The memo pollution test

A common mistake is writing `def word_break_memo(s, word_dict, memo={})`. Python evaluates default arguments once at function definition time, so `memo` is the same dict across all calls. The second call with a different input reads stale cache entries from the first call. Always initialize `memo` inside the function body or use `@lru_cache` with explicit cache management.
