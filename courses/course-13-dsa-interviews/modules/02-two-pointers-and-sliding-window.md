# Arrays, Two-Pointers & Sliding Window

> **Module 02 · Course 13** — Arrays are the substrate of half the Tier-1 problem set. Two-pointers and sliding window are the two transformations that take brute-force O(n²) or O(n·k) array scans down to O(n). The skill is not knowing the transforms exist — it's deciding *which* variant to use, setting up the invariant precisely, and terminating without an off-by-one.

---

## The pattern space — four variants, four trigger conditions

```
Problem shape                         Pattern
──────────────────────────────────    ──────────────────────────────────
Sorted array, pair/triplet target     Opposite-end two-pointer
Cycle detection / find middle         Fast-slow (Floyd's)
Fixed-length subarray property        Fixed-size sliding window
Variable-length subarray property     Dynamic (shrink-when-invalid) window
Subarray sum equals target            Prefix sum (hash map for exact sums)
In-place rearrangement                Dutch National Flag / partition pointer
```

Choosing wrong costs you the problem. Before writing a line of code, ask: is the array sorted? Is there a target sum or a length constraint? That answer routes you to the right variant.

---

## Variant 1 — Opposite-end two-pointers

**When to use:** sorted array, looking for a pair (or triplet) that satisfies a sum or distance condition.

**Invariant:** `left < right` always. Move `left` right to increase the sum, move `right` left to decrease it. Stop when they meet.

```python
def two_sum_sorted(nums: list[int], target: int) -> list[int]:
    """Returns indices [i, j] where nums[i] + nums[j] == target. O(n) time, O(1) space."""
    left, right = 0, len(nums) - 1
    while left < right:
        total = nums[left] + nums[right]
        if total == target:
            return [left, right]
        if total < target:
            left += 1      # need a larger sum
        else:
            right -= 1     # need a smaller sum
    return []
```

**Three-sum extension.** Fix the first element with an outer loop (O(n)) and run opposite-end two-pointer on the remainder (O(n)) — total O(n²), which beats the brute-force O(n³). The key step: sort first, then skip duplicates at both the outer and inner levels:

```python
def three_sum(nums: list[int]) -> list[list[int]]:
    nums.sort()
    result: list[list[int]] = []
    for i in range(len(nums) - 2):
        if i > 0 and nums[i] == nums[i - 1]:
            continue                          # skip duplicate outer element
        left, right = i + 1, len(nums) - 1
        while left < right:
            total = nums[i] + nums[left] + nums[right]
            if total == 0:
                result.append([nums[i], nums[left], nums[right]])
                while left < right and nums[left] == nums[left + 1]:
                    left += 1
                while left < right and nums[right] == nums[right - 1]:
                    right -= 1
                left += 1
                right -= 1
            elif total < 0:
                left += 1
            else:
                right -= 1
    return result
```

**Complexity:** O(n²) time after O(n log n) sort. Space: O(1) auxiliary ignoring the output list.

---

## Variant 2 — Fast/slow pointers (Floyd's)

**When to use:** detect a cycle in a linked list or array, find the middle of a linked list, find the start of a cycle.

**Invariant:** `fast` moves two steps per iteration, `slow` moves one. If a cycle exists, they will meet inside it.

```python
from typing import Optional

class ListNode:
    def __init__(self, val: int = 0, next: "Optional[ListNode]" = None):
        self.val = val
        self.next = next

def has_cycle(head: Optional[ListNode]) -> bool:
    slow = fast = head
    while fast and fast.next:
        slow = slow.next
        fast = fast.next.next
        if slow is fast:
            return True
    return False

def find_cycle_start(head: Optional[ListNode]) -> Optional[ListNode]:
    """Returns the node where the cycle begins, or None."""
    slow = fast = head
    while fast and fast.next:
        slow = slow.next
        fast = fast.next.next
        if slow is fast:
            break
    else:
        return None
    # Reset slow to head; both advance one step — they meet at the cycle start.
    slow = head
    while slow is not fast:
        slow = slow.next
        fast = fast.next
    return slow
```

The math behind the reset: if the pre-cycle length is `a`, cycle length is `c`, and the meeting point is `b` steps into the cycle, then `a ≡ (c - b) (mod c)`. Moving `slow` back to head and advancing both one step at a time makes them meet exactly at the cycle entry — you don't need to know a, b, or c.

**Finding the middle** (also used in merge sort on linked lists):

```python
def middle_node(head: Optional[ListNode]) -> Optional[ListNode]:
    slow = fast = head
    while fast and fast.next:
        slow = slow.next
        fast = fast.next.next
    return slow   # for even-length, returns the second middle
```

---

## Variant 3 — Fixed-size sliding window

**When to use:** "maximum/minimum/average of every subarray of length k," "find an anagram," anything with a fixed-width window.

**Invariant:** window is always exactly k elements wide; slide by adding the right element and removing the left.

```python
def max_sum_subarray_k(nums: list[int], k: int) -> int:
    """Maximum sum of any contiguous subarray of exactly length k. O(n), O(1)."""
    if len(nums) < k:
        raise ValueError("array shorter than window")
    window_sum = sum(nums[:k])
    best = window_sum
    for i in range(k, len(nums)):
        window_sum += nums[i] - nums[i - k]   # add right, subtract left
        best = max(best, window_sum)
    return best
```

**Find all anagrams of p in s** (fixed window = `len(p)`):

```python
from collections import Counter

def find_anagrams(s: str, p: str) -> list[int]:
    """Returns start indices of all anagrams of p in s. O(n) time, O(1) space (fixed alphabet)."""
    if len(p) > len(s):
        return []
    need = Counter(p)
    window = Counter(s[:len(p)])
    result = []
    if window == need:
        result.append(0)
    for i in range(len(p), len(s)):
        right_char = s[i]
        left_char = s[i - len(p)]
        window[right_char] += 1
        window[left_char] -= 1
        if window[left_char] == 0:
            del window[left_char]     # keep Counter clean for equality check
        if window == need:
            result.append(i - len(p) + 1)
    return result
```

---

## Variant 4 — Dynamic (variable) sliding window

**When to use:** "longest subarray satisfying property P," "minimum window containing all of X" — the window grows when the condition is not yet met and shrinks when it becomes invalid or you want to minimise length.

**The template:**

```python
left = 0
state = ...          # whatever tracks the window's property (counter, sum, set)
result = ...

for right in range(len(s)):
    # expand: add s[right] to state
    ...

    while <window is invalid or can be tightened>:
        # shrink: remove s[left] from state
        ...
        left += 1

    # record result at this valid window
    result = max(result, right - left + 1)   # or min, or whatever
```

**Longest substring without repeating characters** (classic):

```python
def length_of_longest_substring(s: str) -> int:
    seen: dict[str, int] = {}    # char -> most-recent index
    left = 0
    best = 0
    for right, ch in enumerate(s):
        if ch in seen and seen[ch] >= left:
            left = seen[ch] + 1   # jump left past the duplicate
        seen[ch] = right
        best = max(best, right - left + 1)
    return best
```

Note: this uses a "jump left" shortcut instead of the standard shrink loop because we only ever need to skip one duplicate character. Using the template more literally (and more generally):

```python
def length_of_longest_substring_general(s: str) -> int:
    freq: dict[str, int] = {}
    left = 0
    best = 0
    for right, ch in enumerate(s):
        freq[ch] = freq.get(ch, 0) + 1
        while freq[ch] > 1:           # shrink until no duplicate
            freq[s[left]] -= 1
            if freq[s[left]] == 0:
                del freq[s[left]]
            left += 1
        best = max(best, right - left + 1)
    return best
```

**Minimum window substring** (harder, but same template):

```python
from collections import Counter

def min_window(s: str, t: str) -> str:
    need = Counter(t)
    missing = len(t)              # how many chars still needed
    left = 0
    best_start = 0
    best_len = float("inf")

    for right, ch in enumerate(s):
        if need[ch] > 0:
            missing -= 1
        need[ch] -= 1             # need can go negative (we have extras)

        if missing == 0:          # valid window: try to shrink
            while need[s[left]] < 0:
                need[s[left]] += 1
                left += 1
            if right - left + 1 < best_len:
                best_len = right - left + 1
                best_start = left
            # advance left one more to break current valid window and look for shorter
            need[s[left]] += 1
            missing += 1
            left += 1

    return s[best_start:best_start + best_len] if best_len < float("inf") else ""
```

---

## Prefix sums — reframe subarray sums as point differences

**When to use:** "number of subarrays with sum == k," "subarray sum divisible by k," any exact-sum query where you cannot sort.

**Core identity:** `sum(nums[i:j+1]) = prefix[j+1] - prefix[i]`

To find "number of subarrays with sum equal to k" in O(n):

```python
from collections import defaultdict

def subarray_sum_equals_k(nums: list[int], k: int) -> int:
    count = 0
    prefix = 0
    freq: dict[int, int] = defaultdict(int)
    freq[0] = 1                 # empty prefix (sum = 0) exists once

    for num in nums:
        prefix += num
        count += freq[prefix - k]   # how many prefixes ended at sum = prefix-k
        freq[prefix] += 1

    return count
```

**Why it works:** if `prefix[j] - prefix[i] == k` then `nums[i:j]` sums to k. For every j, we look up how many prior prefixes equal `prefix[j] - k`. The hash map lookup is O(1), so the full pass is O(n).

**2D prefix sum** (for grid problems):

```python
def build_2d_prefix(grid: list[list[int]]) -> list[list[int]]:
    m, n = len(grid), len(grid[0])
    P = [[0] * (n + 1) for _ in range(m + 1)]
    for i in range(1, m + 1):
        for j in range(1, n + 1):
            P[i][j] = grid[i-1][j-1] + P[i-1][j] + P[i][j-1] - P[i-1][j-1]
    return P

def query_2d(P: list[list[int]], r1: int, c1: int, r2: int, c2: int) -> int:
    return P[r2+1][c2+1] - P[r1][c2+1] - P[r2+1][c1] + P[r1][c1]
```

---

## In-place tricks — Dutch National Flag and partition

**When to use:** "sort array of three values in-place," "partition by a pivot," "move zeros to end."

**Dutch National Flag (three-way partition):**

```python
def sort_colors(nums: list[int]) -> None:
    """Sort [0, 1, 2] in-place. O(n) time, O(1) space. (LeetCode 75)"""
    low = 0                 # boundary of 0-region
    mid = 0                 # current pointer
    high = len(nums) - 1    # boundary of 2-region

    while mid <= high:
        if nums[mid] == 0:
            nums[low], nums[mid] = nums[mid], nums[low]
            low += 1
            mid += 1
        elif nums[mid] == 1:
            mid += 1
        else:               # nums[mid] == 2
            nums[mid], nums[high] = nums[high], nums[mid]
            high -= 1
            # do NOT increment mid: the swapped-in value is unexamined
```

The invariant to hold in your head: `nums[:low]` is all-0, `nums[low:mid]` is all-1, `nums[high+1:]` is all-2. `mid` to `high` is the unprocessed region.

---

## Common mistakes

| Mistake | Symptom | Fix |
|---------|---------|-----|
| Off-by-one on window size | `right - left` gives length k-1 when you want k | Window length is `right - left + 1`; condition to start recording is `right >= k - 1` |
| Forgetting to shrink after updating result | Dynamic window never stops growing | The `while <invalid>` shrink loop must run before (for minimum length) or after (for maximum length) recording |
| Moving `left` past `right` in dynamic window | `left > right`, negative window size, wrong results | Add `left <= right` guard in the shrink loop's condition |
| Mutating frequency counter without cleanup | Counter key with value 0 stays in the map, breaking equality checks | Delete keys when they reach 0, or use `Counter` subtraction with `+Counter()` to strip zeros |
| Using two-pointer on unsorted input without sorting first | Random pair order; pointers move in the wrong direction | Sort first; state the O(n log n) sorting cost as part of the overall complexity |
| In Dutch National Flag: incrementing `mid` after swapping with `high` | The element swapped in from `high` is unexamined — it might be a 0 or 2 | Only increment `mid` after swaps with `low`, not with `high` |
| Prefix sum off by one | `sum(nums[i:j])` vs `sum(nums[i:j+1])` — constant confusion over inclusive/exclusive ends | Define `prefix[i] = sum(nums[:i])` (exclusive right), then `sum(nums[i:j]) = prefix[j] - prefix[i]` and write it the same way every time |

> **War story.** At SAP, reviewing a log-analysis pipeline, a colleague had implemented a "find the longest run of metric values below a threshold" check with an O(n²) nested scan — which worked fine at 1k samples in the test harness but silently blew the 30-second Lambda timeout at 500k samples in production. The fix was a fifteen-line sliding window. The test harness had used n = 1000; the only thing that would have caught this earlier was an explicit "at n = 10⁶ this is 10¹² operations, so O(n²) is out" step during design. The TALK-THROUGH framework's Step 1 (clarify n) and Step 4 (check complexity class against constraints) exists precisely to catch this before the code is written.

---

## Checkpoint

You are ready to move on when you can, without looking anything up:

1. Name the four two-pointer / sliding-window variants and their trigger conditions from memory.
2. Implement opposite-end two-pointer for two-sum on a sorted array in under 60 seconds.
3. Explain why `left` must not be incremented after swapping with `high` in Dutch National Flag.
4. Write the dynamic sliding-window template (expand right, shrink left, record) from memory.
5. Explain why `freq[prefix - k]` in the subarray-sum-equals-k solution needs a `freq[0] = 1` initialisation.
6. Given "longest subarray with at most k distinct characters," adapt the template and state the complexity.
7. Find the bug: a fixed-window loop that starts at `i = k` but checks `nums[i - k + 1 : i + 1]` — off-by-one or correct?

➡ Next up: **Hashing, Stacks, Queues & Heaps** — when to use a monotonic stack vs a deque vs a heap, and the subtle bugs that come from each.
