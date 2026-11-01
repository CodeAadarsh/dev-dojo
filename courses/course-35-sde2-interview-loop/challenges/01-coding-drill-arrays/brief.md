# Coding Drill: Merge Intervals

The Grafana Labs screening call starts. The interviewer shares the problem on the collaborative editor and says: *"You have 35 minutes. Walk me through your thinking as you go — I'm less interested in the final answer than in how you break down the problem."*

You've seen this problem before. The candidates who fail it aren't stuck on the algorithm — they rush, skip the walkthrough, and hand in code with an untested edge case at the 30-minute mark.

This drill is a 25-minute timed round. The verifier is pytest. Communication checklist is below.

## Context

`setup.sh` plants a starter project in your work directory:

```
~/.kube-dojo-work/01-coding-drill-arrays/
├── solution.py          # one function stub; implement it
└── tests/
    └── test_sample.py   # four visible tests you can run locally
```

## Prerequisites

```bash
cd ~/.kube-dojo-work/01-coding-drill-arrays
python3 -m venv .venv && . .venv/bin/activate
pip install pytest
```

## The Problem

**Merge Intervals** (LeetCode 56 equivalent)

Given a list of intervals `[[start, end], ...]` where `start <= end`, merge all overlapping intervals and return the merged list sorted by start time.

Two intervals `[a, b]` and `[c, d]` overlap if `c <= b` (the second starts before or when the first ends).

**Examples:**

| Input | Output |
|-------|--------|
| `[[1,3],[2,6],[8,10],[15,18]]` | `[[1,6],[8,10],[15,18]]` |
| `[[1,4],[4,5]]` | `[[1,5]]` |
| `[[1,4],[0,4]]` | `[[0,4]]` |
| `[[1,4],[0,2],[3,5]]` | `[[0,5]]` |

**Constraints:**

- `1 <= len(intervals) <= 10^4`
- `intervals[i].length == 2`
- `0 <= start <= end <= 10^4`

**Target:** O(n log n) time (sort dominates), O(n) space for output.

## Mission

Implement `merge_intervals(intervals: List[List[int]]) -> List[List[int]]` in `solution.py`.

> **Set a 25-minute timer now.** The constraint is real: this problem is straightforward — the clock is what makes it an interview.

## Timed-Round Communication Checklist

Tier-1 interviewers score on *process*, not just output. Before writing a single line of code:

1. **Restate the problem** in your own words, confirm your understanding. (30 sec)
2. **Clarify edge cases** out loud: empty input, single interval, already merged, input not sorted. (1 min)
3. **State your approach and complexity** before coding. "I'll sort by start, then sweep — O(n log n) sort + O(n) sweep = O(n log n) overall." (1 min)
4. **Write the code**, narrating each non-obvious step. (15 min)
5. **Test by hand** on at least two examples before you say "done." (3 min)
6. **State the invariant** that makes your merge correct: "After sorting, any interval that doesn't overlap with `current` starts a new group."

Failing step 5 costs more points than a wrong first draft.

## Common Mistakes

| Mistake | What happens | How to catch it |
|---------|-------------|-----------------|
| Not sorting the input | Merge logic silently produces wrong output on unsorted input | Always state "assume sorted? no? then sort first" |
| Mutating the input list | Spooky action at a distance in the caller | Append to a new result list |
| Off-by-one on overlap: `c < b` instead of `c <= b` | `[1,4],[4,5]` → `[[1,4],[4,5]]` instead of `[[1,5]]` | Test the touching-boundary case first |
| Returning `List[List]` of ints but each element is a `deque` or `tuple` | Type check fails | Append `[start, end]` not `(start, end)` |
| Forgetting to append the last open interval | Drops the final group | Loop appends to pending; remember to flush after the loop |

## Verify

```bash
bash courses/course-35-sde2-interview-loop/challenges/01-coding-drill-arrays/verify.sh
```

All tests green → flag printed.
