# Sliding Window Maximum

A code-review comment on a metrics aggregation service reads:

> *"The `rolling_max` function is correct but it's running O(n·k) — for a 100k-event stream with k=500 that's 50M iterations per call. This is called on every ingest tick. Needs to be O(n)."*

Your job: implement `sliding_window_max` so the verifier's hidden test suite passes, including a correctness check on a 10,000-element array.

## Context

`setup.sh` plants a starter project in your work directory:

```
~/.kube-dojo-work/01-sliding-window-max/
├── solution.py          # one function stub; implement it
└── tests/
    └── test_sample.py   # three visible sample tests you can run
```

## Prerequisites

```bash
cd ~/.kube-dojo-work/01-sliding-window-max
python3 -m venv .venv && . .venv/bin/activate
pip install pytest
```

## Mission

Implement `sliding_window_max(nums: List[int], k: int) -> List[int]`.

Given an integer array `nums` and a window size `k`, return a list where each element is the maximum of the contiguous subarray `nums[i : i+k]`, for every valid starting index `i`.

**Examples:**

| Input | k | Output |
|-------|---|--------|
| `[1, 3, -1, -3, 5, 3, 6, 7]` | 3 | `[3, 3, 5, 5, 6, 7]` |
| `[4, 2, 1]` | 3 | `[4]` |
| `[5, 3, 7, 1]` | 1 | `[5, 3, 7, 1]` |

**Constraints:**

- `1 ≤ k ≤ len(nums) ≤ 10^5`
- `-10^4 ≤ nums[i] ≤ 10^4`

**Target complexity:** O(n) time, O(k) space. An O(n·k) nested loop is too slow — the hidden suite includes n=10,000 and verifies correctness against an oracle; it does not enforce timing, but the design principle is the point.

> The brief does not name the algorithm. Think first, then check the solution.

## Why this matters

The sliding window maximum pattern shows up in:
- Rolling metrics (max CPU in the last 5-minute window)
- Rate-limiter burst detection
- Image processing (max-pooling)
- Any problem asking "for each position, what's the best value in the surrounding window?"

The brute-force nested loop is the obvious first pass. The O(n) trick is the one that separates someone who "knows sliding window" from someone who can *apply* it under a clock.

## Verify

```bash
bash courses/course-13-dsa-interviews/challenges/01-sliding-window-max/verify.sh
```

All tests green → flag printed.
