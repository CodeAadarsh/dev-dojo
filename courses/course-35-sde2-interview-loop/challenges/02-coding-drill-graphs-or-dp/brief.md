# Coding Drill: Longest Increasing Path in a Matrix

The Uber phone screen. The interviewer shares a grid problem. You start with the brute-force DFS, get it right, then freeze when asked: *"This visits the same cell many times — how do you fix it?"* You say "memo" but can't write it cleanly under pressure. The interview ends.

This drill builds the reflex. You have 35 minutes. The verifier is pytest. Set your timer.

## Context

`setup.sh` plants a starter project:

```
~/.kube-dojo-work/02-coding-drill-graphs-or-dp/
├── solution.py          # one function stub; implement it
└── tests/
    └── test_sample.py   # four visible tests you can run locally
```

## Prerequisites

```bash
cd ~/.kube-dojo-work/02-coding-drill-graphs-or-dp
python3 -m venv .venv && . .venv/bin/activate
pip install pytest
```

## The Problem

**Longest Increasing Path in a Matrix** (LeetCode 329 equivalent)

Given an `m × n` integer matrix, return the length of the longest path along which each next value is **strictly greater** than the previous. You may move in the four cardinal directions (up, down, left, right) — no diagonals, no revisiting cells in the same path.

**Examples:**

```
Matrix A:
 9  9  4
 6  6  8
 2  1  1
Longest path: 1 → 2 → 6 → 9 (length 4)
Answer: 4

Matrix B:
 1  2  3
 6  5  4
Longest path: 1 → 2 → 3 → 4 → 5 → 6 (snake across both rows)
Answer: 6

Matrix C:
 1
Answer: 1
```

**Constraints:**

- `m == len(matrix)`, `n == len(matrix[0])`
- `1 <= m, n <= 200`
- `0 <= matrix[i][j] <= 2^31 - 1`

**Target:** O(m × n) time, O(m × n) space (memo cache). Each cell visited at most once across all DFS calls.

## Mission

Implement `longest_increasing_path(matrix: List[List[int]]) -> int` in `solution.py`.

> **Set a 35-minute timer.** The brute-force recursive DFS without memo is the natural first cut. Don't stop there — the hidden tests include a 200×200 matrix that will TLE the brute-force approach.

## Timed-Round Communication Checklist

1. **Restate:** "Find the longest strictly increasing path, cardinal directions only."
2. **Clarify:** Can the path revisit a cell? (No — it can't, because the values must be strictly increasing and revisiting would require going back to a smaller value.) Can we start anywhere? (Yes.) 
3. **Approach:** "DFS from every cell. At each cell, recurse into neighbors that are strictly larger. Cache the result for each cell — if I've already computed the longest path from `(r, c)`, I don't need to recompute it." State the complexity: O(m×n) with memo.
4. **Code** with narration.
5. **Test** example A and B by hand before claiming done.
6. **Gotcha to mention:** "There are no cycles in this DFS because we only move to strictly larger values — so we don't need a visited set per path. That's the key simplification that makes memoization clean here."

## Why This Is Hard Under a Clock

Memoization on a graph DFS is a pattern, not an algorithm. The instinct under pressure is to reach for a `visited` set (appropriate for BFS/cycle detection, unnecessary and wrong here). Recognizing that "strictly increasing = no cycles = memo is safe" is the SDE-2 signal.

## Debugging the Implementation

**My answer is off by one on some inputs.** Check your base case: a single cell with no valid neighbors should return `1` (itself), not `0`. If you return `0` from a dead end and add 1 up the call chain, the math works — but if you return `1` from a dead end (the cell itself) and add 1 again at the caller, you're off by one.

Consistent pattern: `dfs(r, c)` returns the longest path *starting at (r, c)*, including the cell itself. Dead end → `1`. Otherwise `1 + max(dfs(nr, nc) for valid neighbors)`.

**Memo key.** Use a 2D array `memo[r][c]` initialized to `0` (unvisited) or a dict. A value of `0` means "not yet computed." Since the minimum valid return is `1`, you can distinguish "not computed" from "computed" with `memo[r][c] != 0`.

**Wrong answer on a matrix with equal adjacent values.** Recall the constraint is *strictly* increasing. A neighbor with the same value is not a valid move.

**Stack overflow on a 200×200 matrix.** Python's default recursion limit is 1000. Call `sys.setrecursionlimit(200*200 + 10)` at the top of your implementation, or switch to iterative with an explicit stack.

## Verify

```bash
bash courses/course-35-sde2-interview-loop/challenges/02-coding-drill-graphs-or-dp/verify.sh
```

All tests green → flag printed.
