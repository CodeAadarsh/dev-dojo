# Solution — Top K Frequent Elements

Two correct approaches exist, with different complexity profiles. Know both.

---

## Approach 1: Min-heap (O(n log k))

```python
from typing import List
from collections import Counter
import heapq


def top_k_frequent(nums: List[int], k: int) -> List[int]:
    counts = Counter(nums)                    # O(n)
    # heapq.nlargest uses a min-heap of size k internally → O(n log k)
    return heapq.nlargest(k, counts, key=counts.get)
```

Or written out explicitly (same complexity, more readable under interview pressure):

```python
def top_k_frequent(nums: List[int], k: int) -> List[int]:
    counts = Counter(nums)
    heap = []
    for num, freq in counts.items():
        heapq.heappush(heap, (freq, num))
        if len(heap) > k:
            heapq.heappop(heap)   # evict the least-frequent we've seen so far
    return [num for freq, num in heap]
```

**Why O(n log k):** The heap never grows beyond size k. Each `heappush` + `heappop` pair is O(log k). We iterate over at most n distinct elements → O(n log k) total.

---

## Approach 2: Bucket sort (O(n))

Observation: frequency values are bounded — an element can appear at most `n` times. So we can create `n+1` buckets indexed by frequency, place each element in its bucket, then read from the highest-frequency buckets down until we have k elements.

```python
def top_k_frequent(nums: List[int], k: int) -> List[int]:
    counts = Counter(nums)                    # O(n)
    buckets: list = [[] for _ in range(len(nums) + 1)]
    for num, freq in counts.items():
        buckets[freq].append(num)
    result = []
    for freq in range(len(buckets) - 1, -1, -1):
        result.extend(buckets[freq])
        if len(result) >= k:
            return result[:k]
    return result   # unreachable given valid k
```

**Why O(n):** Building `counts` is O(n). Filling `buckets` is O(distinct elements) ≤ O(n). The reverse scan visits at most n+1 bucket entries in total. No sorting, no heap operations.

---

## When to use which

| Approach | Time | Space | Use when |
|----------|------|-------|----------|
| Sort | O(n log n) | O(n) | k ≈ n, throwaway script |
| Min-heap | O(n log k) | O(n + k) | k << n, memory-sensitive |
| Bucket sort | O(n) | O(n) | k is any value, max throughput required |

In an interview: **name both**, implement the heap (it's shorter and more obviously correct), then mention bucket sort as the O(n) follow-up. Interviewers at Tier-1 companies specifically ask "can you do better than O(n log n)?" — that's the signal to reach for one of these.

---

## Common mistakes

| Mistake | Symptom | Fix |
|---------|---------|-----|
| Using `sorted()` on the full counter | O(n log n) — correct but fails the spirit of the problem | Use heap or bucket sort |
| Returning a set instead of a list | Type error in tests | Wrap with `list(...)` |
| Off-by-one on bucket-sort array size | `IndexError` for elements with freq = n | Allocate `len(nums) + 1` buckets (indices 0..n inclusive) |
| Evicting from min-heap with wrong condition | Too many or too few elements in heap | Evict when `len(heap) > k`, not `>= k` |

> **War story.** In a Tier-1 virtual screen I implemented the heap version correctly but returned `[num for freq, num in heap]` without checking the output length. The test case was k=2 on `[1,1,1,2,2,3]` — the heap contained exactly 2 elements so it *happened* to pass. The follow-up test had k=1 on 3 distinct elements: the heap accumulated all 3 before I started evicting. I was pushing *then* evicting when `> k`, but I had written `>= k` — so the heap was capped at k-1 elements after each step, and the final result was missing an element. The fix is `if len(heap) > k: heapq.heappop(heap)` (strictly greater). Alternatively, `heapq.nlargest(k, counts, key=counts.get)` wraps this correctly so you never write the eviction loop at all.

---

## Apply and verify

```bash
cd ~/.kube-dojo-work/03-top-k-frequent
.venv/bin/pytest tests/test_sample.py -v
bash courses/course-13-dsa-interviews/challenges/03-top-k-frequent/verify.sh
```
