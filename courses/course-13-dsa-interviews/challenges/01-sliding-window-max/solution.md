# Solution — Sliding Window Maximum

The O(n) approach uses a **monotonic decreasing deque** of indices.

```python
from typing import List
from collections import deque


def sliding_window_max(nums: List[int], k: int) -> List[int]:
    dq: deque = deque()   # stores indices; front is always the max of current window
    result = []

    for i, val in enumerate(nums):
        # 1. Evict indices that have fallen outside the window
        while dq and dq[0] < i - k + 1:
            dq.popleft()

        # 2. Maintain decreasing order: evict from back any index whose value
        #    is ≤ current value (it can never be a window max now or later)
        while dq and nums[dq[-1]] <= val:
            dq.pop()

        dq.append(i)

        # 3. Window is complete once we've seen k elements
        if i >= k - 1:
            result.append(nums[dq[0]])

    return result
```

## Why it works

**The deque stores indices, ordered so `nums[dq[0]]` is always the window maximum.**

Invariant: values at stored indices are strictly decreasing from front to back.

Step 2 is the key insight: if `nums[j] <= nums[i]` and `j < i`, index `j` can *never* be the maximum of any future window — `i` is newer *and* at least as large. We can discard `j` forever. This is why the deque never grows beyond `k` and why the total work across all iterations is O(n): each index is pushed and popped at most once.

Step 1 is bookkeeping: once `dq[0]` is more than `k-1` steps behind the current index, it has left the window.

## Complexity

| | Bound | Why |
|---|---|---|
| Time | O(n) | Each index enqueued and dequeued at most once |
| Space | O(k) | Deque holds at most k indices |

## Common mistakes

| Mistake | Symptom | Fix |
|---------|---------|-----|
| Storing *values* instead of *indices* in the deque | Can't evict out-of-window elements (no position info) | Store indices; compare `dq[0] < i - k + 1` |
| Evicting with `<` instead of `<=` in step 2 | Deque retains dominated duplicates, off-by-one on ties | Use `nums[dq[-1]] <= val` |
| Appending to result before `i >= k - 1` | Output has too many elements (partial first window) | Gate with `if i >= k - 1` |
| Starting a new deque per window (reverting to O(nk)) | Correct output, but defeats the pattern | One deque, one pass |

> **War story.** At a Tier-1 screening I implemented this correctly but stored values instead of indices. Step 2 worked fine. Step 1 silently broke because I couldn't tell which value belonged to which position — I was evicting the *value* `3` from the front, but `3` appeared at multiple positions, so I evicted the wrong one. The test with `[3,1,4,1,5,9,2,6]` k=3 failed on the last window. The fix is one word: store the index. Moral: if your deque operation needs position information, store positions.

## Heap alternative (O(n log n))

A max-heap works too. Push `(-val, idx)` pairs; peek at the top; lazily evict when `idx` is outside the window:

```python
import heapq
def sliding_window_max_heap(nums, k):
    heap = []
    result = []
    for i, val in enumerate(nums):
        heapq.heappush(heap, (-val, i))
        while heap[0][1] < i - k + 1:
            heapq.heappop(heap)
        if i >= k - 1:
            result.append(-heap[0][0])
    return result
```

Correct, but O(n log n) — each push is O(log n). The deque is strictly better here because the monotonicity property lets you evict in O(1).

## Apply and verify

```bash
cd ~/.kube-dojo-work/01-sliding-window-max
.venv/bin/pytest tests/test_sample.py -v
bash courses/course-13-dsa-interviews/challenges/01-sliding-window-max/verify.sh
```
