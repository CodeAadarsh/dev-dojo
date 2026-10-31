# Hashing, Stacks, Queues & Heaps

> **Module 03 · Course 13** — Hash maps get over-used, monotonic stacks get under-used, and heaps get misused. This module is about knowing which tool resolves which shape of problem, the O(n) vs O(n log n) fork that a heap/sort decision creates, and the two classes of bugs — mutating while iterating and heaping on the wrong key — that kill otherwise-correct solutions.

---

## Hash maps and sets — when O(1) lookup changes everything

Python's `dict` and `set` are hash tables. Average O(1) insert, lookup, and delete. Worst case O(n) per op (all keys hash to the same bucket), but Python's hash randomisation makes this negligibly rare in practice. Use them without apology when you need fast membership tests or frequency counts.

### The four hash-map interview patterns

**1. Two-sum / complement lookup.** Already covered in Module 01 — the archetype. Store `value → index` and check for `target - value` in O(1) per step.

**2. Frequency counting.** Use `collections.Counter` when you need sorted or most-common access; plain `defaultdict(int)` when you only need fast increment/read:

```python
from collections import Counter, defaultdict

text = "abracadabra"
freq = Counter(text)          # Counter({'a': 5, 'b': 2, 'r': 2, 'c': 1, 'd': 1})
freq.most_common(2)           # [('a', 5), ('b', 2)]

# defaultdict avoids KeyError on first access
word_count: dict[str, int] = defaultdict(int)
for word in text.split():
    word_count[word] += 1
```

**3. Grouping by key.** `defaultdict(list)` groups items without a pre-existence check — the canonical "group anagrams" pattern:

```python
def group_anagrams(strs: list[str]) -> list[list[str]]:
    groups: dict[tuple, list[str]] = defaultdict(list)
    for s in strs:
        key = tuple(sorted(s))    # canonical key for all anagrams of s
        groups[key].append(s)
    return list(groups.values())
```

**4. Memoisation.** Cache recursive results in a dict keyed on the arguments. Python's `@functools.lru_cache` does this automatically, but knowing the underlying dict pattern matters when the state is a mutable object (lists, sets) that `lru_cache` cannot hash:

```python
from functools import lru_cache

@lru_cache(maxsize=None)
def fib(n: int) -> int:
    if n < 2:
        return n
    return fib(n - 1) + fib(n - 2)

# Manual when key is a tuple of state you control:
memo: dict[tuple, int] = {}

def dp(i: int, cap: int) -> int:
    if (i, cap) in memo:
        return memo[(i, cap)]
    # ... compute ...
    memo[(i, cap)] = result
    return result
```

### Sets for O(1) membership

```python
seen: set[int] = set()
for num in nums:
    if num in seen:    # O(1)
        return True
    seen.add(num)
```

`in` on a `list` is O(n). On a `set` or `dict` it is O(1). The single most common asymptotic bug in early-career code is using a list as a membership oracle inside a loop.

---

## Monotonic stack — O(n) sequential "span" problems

A **monotonic stack** maintains elements in strictly increasing or strictly decreasing order by popping elements that violate the order before pushing the new one. The classic application: for each element, find the *nearest* element to the left or right that is larger (or smaller).

**Why O(n)?** Every element is pushed at most once and popped at most once. Total operations: 2n. Amortised O(1) per element.

### Next greater element

```python
def next_greater_element(nums: list[int]) -> list[int]:
    """For each element, find the first larger element to its right. -1 if none."""
    result = [-1] * len(nums)
    stack: list[int] = []    # stores indices; stack values are decreasing

    for i, val in enumerate(nums):
        # pop everything smaller than the current value
        while stack and nums[stack[-1]] < val:
            idx = stack.pop()
            result[idx] = val   # current val is the next greater for idx
        stack.append(i)

    return result
```

Trace on `[2, 1, 3, 4, 1]`:
```
i=0 val=2: stack=[]       → push 0           → stack=[0]
i=1 val=1: 2>1, no pop    → push 1           → stack=[0,1]
i=2 val=3: 1<3, pop 1 → result[1]=3; 2<3, pop 0 → result[0]=3 → stack=[2]
i=3 val=4: 3<4, pop 2 → result[2]=4          → stack=[3]
i=4 val=1: 4>1, no pop    → push 4           → stack=[3,4]
Remaining stack: result[3]=-1, result[4]=-1
→ [-1 was initialised] → result = [3, 3, 4, -1, -1]  ✓
```

### Largest rectangle in histogram

The classic hard problem where the monotonic stack does most of the work:

```python
def largest_rectangle_area(heights: list[int]) -> int:
    stack: list[int] = []   # indices; heights are increasing
    max_area = 0
    # append 0 to flush remaining bars at the end
    for i, h in enumerate(heights + [0]):
        while stack and heights[stack[-1]] >= h:
            height = heights[stack.pop()]
            width = i if not stack else i - stack[-1] - 1
            max_area = max(max_area, height * width)
        stack.append(i)
    return max_area
```

**Daily Temperatures** (nearest warmer day — same structure, different output):

```python
def daily_temperatures(temps: list[int]) -> list[int]:
    result = [0] * len(temps)
    stack: list[int] = []
    for i, t in enumerate(temps):
        while stack and temps[stack[-1]] < t:
            j = stack.pop()
            result[j] = i - j
        stack.append(i)
    return result
```

### Increasing vs decreasing — choosing the flavour

| Problem | Stack order | Pop condition |
|---------|-------------|---------------|
| Next greater element | Decreasing (top = smallest) | Current element > top |
| Next smaller element | Increasing (top = largest) | Current element < top |
| Largest rectangle | Increasing | Current element < top |
| Sliding window maximum (deque) | Decreasing | See next section |

---

## Deque and monotonic deque — O(n) sliding window max

`collections.deque` supports O(1) append and pop from both ends. A **monotonic deque** applies the same pop-invalid-entries idea to a sliding window, giving you the window maximum (or minimum) in O(n) total — not O(n·k).

```python
from collections import deque

def max_sliding_window(nums: list[int], k: int) -> list[int]:
    """Returns the maximum value in each window of width k. O(n) time, O(k) space."""
    dq: deque[int] = deque()    # stores indices; values in dq are decreasing
    result: list[int] = []

    for i, val in enumerate(nums):
        # remove indices outside the current window
        while dq and dq[0] <= i - k:
            dq.popleft()
        # remove indices whose values are smaller than current (they can never be max)
        while dq and nums[dq[-1]] < val:
            dq.pop()
        dq.append(i)
        # window is full starting at index k-1
        if i >= k - 1:
            result.append(nums[dq[0]])

    return result
```

The deque always holds indices of candidates in decreasing value order. The front is always the current window's maximum. Each element enters and leaves the deque at most once: O(n) total, O(k) space.

**Minimum sliding window:** flip the comparison: pop from back when `nums[dq[-1]] > val`.

---

## heapq — min-heap by default, max-heap by negation

Python's `heapq` implements a binary min-heap. The smallest element is always `heap[0]`. Operations:

```python
import heapq

heap: list[int] = []
heapq.heappush(heap, 5)
heapq.heappush(heap, 2)
heapq.heappush(heap, 8)
print(heap[0])              # 2 — minimum, O(1) peek
print(heapq.heappop(heap))  # 2 — pop minimum, O(log n)

# Build from a list in O(n) — faster than n individual pushes (O(n log n))
data = [3, 1, 4, 1, 5, 9]
heapq.heapify(data)         # transforms in-place, O(n)

# Max-heap: negate all values
max_heap = [-x for x in data]
heapq.heapify(max_heap)
print(-heapq.heappop(max_heap))  # largest element
```

**Heap of tuples** — the comparison key is the first element of the tuple:

```python
# Priority queue: (priority, task)
tasks: list[tuple[int, str]] = []
heapq.heappush(tasks, (3, "low priority task"))
heapq.heappush(tasks, (1, "urgent"))
heapq.heappush(tasks, (2, "normal"))
_, next_task = heapq.heappop(tasks)   # "urgent"
```

When comparing on a non-natural key (e.g. heap by frequency, max instead of min, custom object), always push `(key, item)` tuples. **Never rely on the object's default comparison unless you have defined it.**

### Top-K pattern

**K largest elements** — two approaches:

```python
import heapq

def k_largest_sort(nums: list[int], k: int) -> list[int]:
    """O(n log n) time, O(1) space (sorts in-place)."""
    nums.sort(reverse=True)
    return nums[:k]

def k_largest_heap(nums: list[int], k: int) -> list[int]:
    """O(n log k) time, O(k) space. Better when k << n."""
    return heapq.nlargest(k, nums)

def k_largest_heap_manual(nums: list[int], k: int) -> list[int]:
    """Same O(n log k), spelled out. Min-heap of size k."""
    min_heap: list[int] = []
    for num in nums:
        heapq.heappush(min_heap, num)
        if len(min_heap) > k:
            heapq.heappop(min_heap)   # evict the smallest — keeps the k largest
    return sorted(min_heap, reverse=True)
```

**K most frequent elements:**

```python
from collections import Counter

def top_k_frequent(nums: list[int], k: int) -> list[int]:
    """O(n log k). Heap keyed on frequency."""
    freq = Counter(nums)
    # min-heap of (count, element); evict the least-frequent when size > k
    heap: list[tuple[int, int]] = []
    for num, count in freq.items():
        heapq.heappush(heap, (count, num))
        if len(heap) > k:
            heapq.heappop(heap)
    return [num for _, num in heap]


def top_k_frequent_bucket(nums: list[int], k: int) -> list[int]:
    """O(n). Bucket sort by frequency — no heap needed when you know the max frequency."""
    freq = Counter(nums)
    buckets: list[list[int]] = [[] for _ in range(len(nums) + 1)]
    for num, count in freq.items():
        buckets[count].append(num)
    result: list[int] = []
    for count in range(len(buckets) - 1, -1, -1):
        result.extend(buckets[count])
        if len(result) >= k:
            break
    return result[:k]
```

### When a heap beats sorting

| Situation | Sort | Heap | Winner |
|-----------|------|------|--------|
| All k elements up front, one-off | O(n log n) | O(n log k) | Heap when k << n |
| Stream: elements arrive one by one, maintain top-k | Requires re-sort each time: O(n log n) per insert | O(log k) per insert | Heap — no contest |
| k = 1 (just the max) | O(n log n) | O(n) with linear scan | Linear scan — no heap needed |
| k ≈ n (top 90%) | O(n log n) | O(n log n) — heap size ≈ n | Sort (simpler, same cost) |
| Median of a stream | Cannot maintain efficiently | Two heaps (max-heap + min-heap): O(log n) insert, O(1) query | Heap — the standard approach |

**Median of a data stream** — the canonical two-heap problem:

```python
import heapq

class MedianFinder:
    def __init__(self) -> None:
        self._lo: list[int] = []   # max-heap (negated) — lower half
        self._hi: list[int] = []   # min-heap — upper half

    def add_num(self, num: int) -> None:
        heapq.heappush(self._lo, -num)        # push to lower half
        # balance: largest of lower half must be <= smallest of upper half
        heapq.heappush(self._hi, -heapq.heappop(self._lo))
        # keep sizes equal or lower half one larger
        if len(self._hi) > len(self._lo):
            heapq.heappush(self._lo, -heapq.heappop(self._hi))

    def find_median(self) -> float:
        if len(self._lo) > len(self._hi):
            return float(-self._lo[0])
        return (-self._lo[0] + self._hi[0]) / 2.0
```

Each `add_num` is O(log n). Each `find_median` is O(1). This beats sort-and-slice every time the data arrives incrementally.

---

## Common mistakes

| Mistake | Symptom | Fix |
|---------|---------|-----|
| Mutating a dict while iterating it | `RuntimeError: dictionary changed size during iteration` | Iterate over `list(d.keys())` or collect keys to delete, then delete after the loop |
| Heaping on the wrong key | `(item, count)` instead of `(count, item)` — min-heap evicts items by name not by frequency | Always put the comparison key first in the tuple: `(count, item)` |
| Using `heapq` for max without negation | `heapq` is a min-heap — `heappop` gives the smallest, not the largest | Negate values: push `-x`, return `-heappop(heap)` |
| O(n log n) sort when O(n) exists | Sorting to find the top-1, or sorting to group (should use `defaultdict`) | One scan + a dict is O(n); sorting is O(n log n); always ask "can I do this in one pass with a hash map?" |
| Monotonic stack: not storing indices | `while stack and stack[-1] < val` — you need the index for width/distance calculations | Store indices, not values; access the value with `nums[stack[-1]]` |
| Deque for sliding window: forgetting to remove out-of-window indices | Window keeps old entries; front of deque is stale | First check `dq[0] <= i - k` and popleft before checking anything else |
| Counter keys with zero count breaking equality | `Counter({'a': 1, 'b': 0}) != Counter({'a': 1})` even though logically the same | Clean up zero-count keys explicitly, or compare with `+counter` (strips non-positive): `a_clean = +a` |

> **War story.** Reviewing a metrics-aggregation service at SAP, I found a "top-10 noisiest tenants" query running at O(n log n) on every HTTP request — it sorted a 50k-entry frequency map on every call, just to return 10 entries. The fix: maintain a min-heap of size 10 that is updated on each tenant event write (O(log 10) = O(1) effectively) and exposed as a pre-computed result. Latency dropped from 120ms to under 2ms. The heap-vs-sort decision is almost never "which is faster on my laptop right now" — it is "where does the data come from and how often does the question get asked." A heap maintained incrementally on writes is almost always the right answer for a live top-K leaderboard.

---

## Checkpoint

You are ready for the challenges when you can, without looking anything up:

1. Name the four hash-map interview patterns and give a one-line description of each.
2. State why `in` on a `list` is O(n) and on a `set` is O(1), and name one common bug it creates.
3. Explain what "monotonic" means in a monotonic stack and why each element enters and leaves at most once.
4. Implement `next_greater_element` from scratch (no reference) in under 3 minutes.
5. Explain the two-heap median-of-a-stream structure: which heap holds which half, which is the max-heap, which is larger by one when n is odd.
6. For top-K most frequent elements: when should you use the heap approach vs the bucket-sort approach?
7. State the bug in: `heap = []; for x in data: heapq.heappush(heap, x); return heap[0]` when you want the maximum. Fix it.
8. Describe, without code, how to detect the "mutating during iteration" bug in a code review.

➡ Next up: **Linked Lists, Trees & Tries** — pointer manipulation, recursive tree invariants, and the insert/search/prefix loop that interviewers use to test both correctness and code clarity.
