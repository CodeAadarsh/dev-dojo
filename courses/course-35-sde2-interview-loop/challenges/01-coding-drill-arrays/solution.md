# Solution — Merge Intervals

The flag is `KUBE{merge_intervals_sorted_sweep}`.

## The insight

Once you sort intervals by start time, every pair of potentially-overlapping intervals is adjacent in the sorted list. A single left-to-right sweep is enough.

```python
from typing import List


def merge_intervals(intervals: List[List[int]]) -> List[List[int]]:
    if not intervals:
        return []

    # Sort by start time — O(n log n)
    intervals = sorted(intervals, key=lambda x: x[0])

    merged = [intervals[0][:]]   # copy to avoid mutating the input

    for start, end in intervals[1:]:
        # If current interval overlaps with the open group, extend it
        if start <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], end)
        else:
            # No overlap — close the current group, open a new one
            merged.append([start, end])

    return merged
```

## Why it works

**Invariant after sorting:** if interval `j` doesn't overlap with interval `i` (i.e., `j.start > i.end`), then no interval after `j` can overlap with `i` either (all later starts are >= `j.start > i.end`). So once we decide to close a group, we never reopen it.

**The `<=` in `start <= merged[-1][1]`:** intervals sharing an endpoint (`[1,4]` and `[4,5]`) count as overlapping. Using strict `<` is an off-by-one that fails the touching-boundary case.

**`max(merged[-1][1], end)`:** needed for contained intervals — if `[1,10]` is open and `[2,5]` comes in, we must keep the end at 10, not shrink it to 5.

## Complexity

| | Bound | Why |
|---|---|---|
| Time | O(n log n) | Dominated by the sort; the sweep is O(n) |
| Space | O(n) | Output list; sort is in-place on a copy |

## Common mistakes

| Mistake | Symptom | Fix |
|---------|---------|-----|
| Forgetting to sort | Random-looking wrong output on any unsorted input | Sort first, always |
| `start < merged[-1][1]` (strict) | Touching intervals `[1,4],[4,5]` → `[[1,4],[4,5]]` | Use `<=` |
| `merged[-1][1] = end` instead of `max(...)` | `[1,10],[2,5]` → `[[1,5]]` — contained interval shrinks the window | Use `max` |
| Appending `(start, end)` tuples | `isinstance(result[0], list)` check fails | Use `[start, end]` |
| Mutating the input list | Caller's data changes silently | Copy: `intervals = sorted(...)` or `[iv[:] for iv in intervals]` |

## What to say in the interview

After coding, run your examples by hand:

1. `[[1,3],[2,6],[8,10],[15,18]]` sorted is already sorted → sweep: `[1,3]` open, `2<=3` extend to `[1,6]`, `8>6` close+open `[8,10]`, `15>10` close+open `[15,18]` → `[[1,6],[8,10],[15,18]]`. Correct.
2. `[[1,4],[0,2],[3,5]]` → sorted: `[[0,2],[1,4],[3,5]]` → `[0,2]` open, `1<=2` extend to `[0,4]`, `3<=4` extend to `[0,5]` → `[[0,5]]`. Correct.

The interviewer will likely ask: *"Can you do it in O(n) time?"* Answer: no — a comparison sort lower-bound of O(n log n) applies to the general case. If starts are bounded integers you could use counting sort, but that's not worth the complexity unless the interviewer explicitly asks.
