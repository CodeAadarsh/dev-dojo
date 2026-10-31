# Complexity & the Interview Frame

> **Module 01 · Course 13** — You already know Big-O exists. The gap between a candidate who says "O(n log n)" and one who gets the offer is everything else: *which* O, what it actually costs to ignore space, how amortized analysis works, and — most importantly — the structured monologue that stops an interviewer from writing "silent coder" on your sheet.

This module is deliberately light on flashcard definitions and heavy on the parts that derail otherwise-correct solutions in live interviews.

---

## Big-O, Big-Theta, Big-Omega — use the right one

Most engineers say "Big-O" when they mean "Big-Theta," and nobody corrects them in daily work. In an interview room with a principal engineer, being precise is a differentiator.

| Notation | Reads as | Means |
|----------|----------|-------|
| O(f(n)) | "big-O of f" | **Upper bound**: grows no faster than f — pessimistic ceiling |
| Θ(f(n)) | "big-Theta of f" | **Tight bound**: grows at *exactly* the rate of f — both upper and lower |
| Ω(f(n)) | "big-Omega of f" | **Lower bound**: grows no slower than f — best-case floor |

When you say "this sort is O(n²)" you are saying it will never be worse than n². You have not said anything about best case. When you say Θ(n²) you are committing to n²-ish in every case. In an interview, always name the case you are analysing:

```
"The worst-case time complexity is O(n²). The average case is Θ(n log n)."
```

This single distinction tells the interviewer you think about adversarial inputs, not only average paths.

### Complexity classes — fast to slow

```
O(1)        direct index, hash lookup (amortized), bit arithmetic
O(log n)    binary search, balanced BST, halving the search space each step
O(√n)       trial division for primality, some segment-tree queries
O(n)        single scan, two-pointer, hash count, BFS/DFS visiting each node once
O(n log n)  comparison sort, merge sort, divide-and-conquer with O(n) merge
O(n²)       nested loop, brute-force pair search, insertion sort on unsorted data
O(n³)       triple nested loop, Floyd-Warshall on dense graph, naive matrix multiply
O(2ⁿ)       subsets, recursive Fibonacci (unoptimised), brute-force TSP
O(n!)       permutations, brute-force scheduling over n slots
```

A quick gut-check for LeetCode-style constraint boxes: if n ≤ 10⁶ you need O(n) or O(n log n). If n ≤ 10⁴ then O(n²) is borderline acceptable. If n ≤ 20–25 then O(2ⁿ) is fine. State this explicitly: "With n up to 10⁵, a quadratic solution times out, so I need at most O(n log n)."

---

## Amortized analysis — spreading a rare cost

A single operation can be expensive, but if it happens rarely the *amortized* cost (average across a sequence) is low. The canonical example every interviewer knows:

**Python `list.append`:**
- 99% of appends: O(1) — write to the preallocated next slot.
- 1% of appends: O(n) — the backing array is full; allocate a 2× array and copy.

Over n appends: you copy at most 1 + 2 + 4 + … + n ≈ 2n elements total. Spread over n operations that is **O(1) amortised per append**. Python lists guarantee this. When you use `.append()` in a tight loop you are not accidentally hiding an O(n²) — you are using the intended interface.

Other amortised guarantees worth naming aloud in interviews:

| Structure / operation | Expensive worst case | Amortised cost per op |
|-----------------------|---------------------|-----------------------|
| `list.append` (dynamic array) | resize: O(n) | O(1) |
| Stack push/pop sequence | never both expensive simultaneously | O(1) |
| `dict.__setitem__` (rehash) | full rehash: O(n) | O(1) |
| Union-Find with path compression + union by rank | O(log n) without optimisations | O(α(n)) ≈ O(1) |

In interviews the stack amortisation comes up most: "each element is pushed at most once and popped at most once, so the total work across all n iterations is O(n) — the inner `while` loop is not O(n) per outer iteration."

---

## Space complexity — the one candidates forget

Time gets all the attention. Space is what fails production systems at scale and what trips up otherwise-correct interview answers.

```
  Input space               Auxiliary space
  ─────────────             ─────────────────
  The input you             Everything extra you
  can't control             allocate to solve it
  (usually excluded)        (what interviewers mean by "space")
```

When an interviewer asks "what's the space complexity?", they mean auxiliary unless the problem says otherwise. Distinguish them:

```python
def max_elem(nums: list[int]) -> int:
    best = nums[0]          # O(1) auxiliary
    for n in nums:
        best = max(best, n)
    return best
# Total space: O(n) input + O(1) auxiliary. Say: "O(1) extra space."
```

### Recursion stack — the hidden allocator

Every recursive call pushes a stack frame. A depth-d recursion uses O(d) space even if it touches no other data structure. Binary search implemented recursively is O(log n) space. The iterative version is O(1). This matters whenever the interviewer asks "can you reduce memory?":

```python
# recursive: O(log n) space (call stack depth)
def bsearch_rec(arr: list[int], lo: int, hi: int, target: int) -> int:
    if lo > hi:
        return -1
    mid = (lo + hi) // 2
    if arr[mid] == target:
        return mid
    if arr[mid] < target:
        return bsearch_rec(arr, mid + 1, hi, target)
    return bsearch_rec(arr, lo, mid - 1, target)


# iterative: O(1) auxiliary space
def bsearch_iter(arr: list[int], target: int) -> int:
    lo, hi = 0, len(arr) - 1
    while lo <= hi:
        mid = (lo + hi) // 2
        if arr[mid] == target:
            return mid
        if arr[mid] < target:
            lo = mid + 1
        else:
            hi = mid - 1
    return -1
```

### Hash map space and the alphabet assumption

Counting characters with a `dict` is technically O(k) where k is the number of distinct keys. For fixed-alphabet problems (ASCII: 128 chars, lowercase only: 26) k is a constant, so you can say "O(1) extra space." State the assumption: "I'll treat the alphabet size as constant, so the dict is O(1) auxiliary space." For arbitrary unicode strings the assumption breaks — say O(n) instead.

---

## The TALK-THROUGH framework

Silent coding is the single most common reason strong engineers fail live interviews. The seven-step loop below makes your reasoning visible and your signal separable from candidates who just happen to have seen the problem before:

```
1. CLARIFY        ask about edge cases and constraints before touching the board
2. EXAMPLES       draw a small concrete input; trace what the answer should be
3. BRUTE FORCE    name the naive O(n²)/O(2ⁿ) solution first, even if you won't code it
4. OPTIMIZE       say where the waste is and which pattern removes it
5. CODE           implement top-down: function signature → skeleton → bodies
6. TEST           trace your code on the drawn example; probe the edge case
7. COMPLEXITY     time AND space, worst AND average; offer the trade-off
```

### Step 1 — Clarify

Never start coding while an edge-case question is still open. Your first three to five questions narrow the problem to something codeable:

```
"Can the input be empty? Should I return -1, raise, or return an empty list?"
"Are values guaranteed distinct, or can there be duplicates?"
"Is the array sorted? May I sort it if not?"
"What is the largest n I should handle? I want to confirm the time budget."
"Is the answer a single value or all valid answers?"
```

### Step 2 — Examples

Draw it. Even on a phone screen, talk through: "If I have `[2, 7, 11, 15]` and `target = 9`, the answer is `[0, 1]` — let me make sure I have the output format right before I code." This catches a misread before it costs ten minutes of wrong code.

### Step 3 — Brute force first

```
"The naive approach is to check every pair — O(n²) time, O(1) space.
 I won't code it, but naming it makes sure we agree on the problem before
 I jump to the optimised version."
```

Naming the brute force signals that you understand the problem correctly, and it gives you a mental reference to diff against.

### Step 4 — Optimise by spotting the waste

Most optimisations fall into one of four buckets:

```
Recomputing something already known  →  hash map, memoisation, prefix sum
Searching space you don't need       →  binary search, pruning
Iterating over settled elements      →  two-pointer, monotonic structure
Rebuilding state from scratch        →  sliding window, deque
```

Name the bucket before you name the data structure: "I'm recomputing the complement lookup — if I store it in a hash map I can do that in O(1) instead of O(n) per element."

### Step 5 — Code top-down

Start with the function signature and a skeleton, then fill in bodies. This prevents "I started in the middle and now I have a dangling variable":

```python
def two_sum(nums: list[int], target: int) -> list[int]:
    seen: dict[int, int] = {}        # value -> index
    for i, num in enumerate(nums):
        complement = target - num
        if complement in seen:
            return [seen[complement], i]
        seen[num] = i
    return []
```

### Step 6 — Test by tracing

Trace your code on the small example you drew, step by step:

```
nums = [2, 7, 11, 15], target = 9
i=0  num=2  complement=7  seen={}      → miss  → seen={2:0}
i=1  num=7  complement=2  seen={2:0}   → hit   → return [0, 1]  ✓
```

Then probe the edge case: empty list, target not present, duplicate values. If a case fails, say "I see the bug — let me fix it." Narrating your own bug discovery is a positive signal.

### Step 7 — Complexity

Never just say "O(n)." Say:

```
"Time: O(n) — one pass, O(1) hash lookup per step. Worst case: the pair is at
 the end or doesn't exist, so we scan the full array — still O(n).
 Space: O(n) auxiliary for the hash map — in the worst case we store every element
 before finding the answer. If memory is constrained, sort first and use two pointers
 for O(1) extra space at the cost of O(n log n) time."
```

That last sentence — volunteering the trade-off — is the line that gets you the "strong hire" tick.

---

## Debugging complexity claims

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Inner loop is `range(i, n)` and you called it O(n²) | Triangular sum: actual iterations ≈ n²/2; still Θ(n²) but the constant matters on tight time limits | Compute `n*(n-1)/2` explicitly and decide if n²/2 fits the constraint |
| Two separate O(n) loops, called O(n²) | Independent loops *add*, they don't multiply | O(n) + O(n) = O(n); it's Θ(n) total |
| Recursive solution "O(log n) time, O(1) space" | The call stack is O(log n) frames deep | Add "O(log n) auxiliary space for the call stack" |
| Hash-map solution "O(1) space, full stop" | For non-fixed alphabets the map can hold n distinct keys | Qualify: "O(1) extra space assuming fixed alphabet; O(n) otherwise" |
| Heap / `heapq.nlargest(k, arr)` called O(n) | `heapq.nlargest` internally uses a heap of size k and does n comparisons | O(n log k); if k ≈ n that degrades to O(n log n) |
| Claiming O(n) when you `sort` inside a loop | Each sort is O(n log n); calling it n times is O(n² log n) | Pre-sort once outside, or rethink the approach |

> **War story.** In a Google interview loop, a candidate I know got the optimal sliding-window solution right — O(n) time — then said "space is O(1)" because he "only used two pointers and a variable." He had allocated a `collections.deque` three lines earlier for the monotonic window-max sub-problem and blanked on it. The interviewer asked "are you sure?" twice. He confirmed O(1) twice. The deque is bounded by the window size k, so the real answer is O(k) — not O(1), not O(n), but O(k). Offer rescinded for that round. The habit to build: after you write the last line of code, scan every variable you declared and state its size bound. Name every data structure you allocate.

---

## Checkpoint

You're ready for the challenges when you can, without looking anything up:

1. Explain the difference between O, Θ, and Ω using a concrete function (not definitions — a real Python example).
2. State the amortised cost of `list.append` and trace where the O(n) copy cost actually goes across n appends.
3. Recite the seven-step TALK-THROUGH framework in order from memory.
4. For a recursive function of depth d that allocates no other structures, give the space complexity.
5. For a nested loop where the inner runs `range(i+1, n)`, compute the exact iteration count and give Θ.
6. Explain why reporting "O(1) space" for a hash-map solution requires an alphabet-size assumption.
7. Offer the time/space trade-off between a hash-map two-sum and a sorted two-pointer two-sum without being prompted.

➡ Next up: **Arrays, Two-Pointers & Sliding Window** — the idea is simple; knowing when to use opposite-ends vs same-direction vs a full window, and how to shrink it without an off-by-one, is not.
