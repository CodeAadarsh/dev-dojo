# The Coding Round

> **Module 02 · Course 35** — The coding round is not a LeetCode contest. It is a 45-minute communication exercise that happens to involve code. The interviewer already knows the answer. What they don't know — and what they are paid to find out — is whether you think like someone who can debug production at 2 AM without a rubber duck.

This module is about the protocol: the exact communication loop that separates candidates who "know the algorithm" from candidates who get the offer.

---

## The communication loop

Every coding round, regardless of problem or company, should follow the same six-step loop:

```
CLARIFY → EXAMPLES → APPROACH → CODE → TEST → COMPLEXITY
```

Each step has a purpose. Skipping one does not make you faster — it makes the interviewer less confident and more likely to downlevel you.

### Step 1: Clarify

Before you write anything, ask. Two to three targeted questions, not a blanket "can you tell me more?"

What to ask:
- **Input range and type.** "Can the array be empty? Can values be negative? Unicode or ASCII only?"
- **Output shape.** "Return the indices or the values? Sorted or unsorted?"
- **Edge cases that change the algorithm.** "Can k equal n? Can k be zero?"

What not to ask:
- Things you can infer from context ("I assume ints?" when the problem says integers).
- Open questions that make you look unprepared ("What should the function do?").

A 90-second clarification that surfaces one assumption the interviewer hadn't thought about is a strong positive signal. You are demonstrating the same discipline you would show in a requirements meeting.

### Step 2: Examples

Work through one given example by hand, out loud, to confirm your understanding. Then derive one edge-case example yourself.

The point of this step is not to test the algorithm. It is to externalize your mental model so the interviewer can see whether you have the right one. If your hand-trace produces the wrong answer, you'll find out now — not 20 minutes into coding.

```
"For [1, 3, -1, -3, 5] with k=3, the first window is [1,3,-1], max is 3.
 Second is [3,-1,-3], max is 3. Third is [-1,-3,5], max is 5.
 So output is [3, 3, 5]. My own edge case: all elements identical — output should
 be the same value repeated. And: k equals array length — single output element."
```

### Step 3: Approach

State your approach before you code. Not in pseudocode — in plain English, out loud, to the interviewer.

"My first instinct is a brute force: scan each window in O(k) → total O(n·k). I see a better path: a monotonic deque that tracks the maximum in the current window, processing each element once → O(n). Let me go with that — should I talk through why the deque works before I code?"

Two things are happening here:
1. You are giving the interviewer a chance to redirect you if you've picked the wrong approach. They will. That's not failure — it's a hint, and handling it gracefully is a positive signal.
2. You are proving your thought process exists before your hands start moving.

If you can see the O(n) solution, say so. If you can't, say "I can see an O(n·k) brute force immediately; let me think for a moment whether there's something better" — and then think, out loud, for 60–90 seconds. Silence is only acceptable for one minute, and only if you announce it ("Give me 60 seconds to think through the data structure here").

### Step 4: Code

Now you write. Move at a steady pace — not rushed, not painstakingly slow. Use clear variable names. If you get to a part you're uncertain about, narrate the uncertainty: "I need to decide whether to pop from the front here — yes, because the index at the front is outside the window."

You do not need to write perfect code on the first pass. What you must not do is silently stall. If you're stuck, say "I'm going to put a comment here and come back — I want to get the skeleton right first."

```python
from collections import deque

def sliding_window_max(nums, k):
    q = deque()   # stores indices; front always holds index of max for current window
    result = []
    for i, val in enumerate(nums):
        # pop indices no longer in window
        while q and q[0] < i - k + 1:
            q.popleft()
        # maintain decreasing order: pop indices with smaller values
        while q and nums[q[-1]] < val:
            q.pop()
        q.append(i)
        # window is full after index k-1
        if i >= k - 1:
            result.append(nums[q[0]])
    return result
```

### Step 5: Test

When you finish, do not say "I think that's right." Walk through your own test case, tracing the code execution, out loud. Pick one example that exercises the core path and one edge case.

Most candidates skip this. Most candidates also get surprised by a test-case failure the interviewer points out. The two facts are related.

The interviewer is watching: can you catch your own bugs? That is a core SDE behavior.

```
"Let me trace k=3, [1,3,-1,-3,5,3,6,7].
 i=0, val=1: q=[0]. i<k-1, no output.
 i=1, val=3: 3>nums[0]=1, pop 0, append 1. q=[1].
 i=2, val=-1: append 2. q=[1,2]. i=k-1=2, output nums[1]=3. ✓
 ..."
```

You don't need to trace every step. Two or three iterations plus the boundary condition is enough to show the discipline.

### Step 6: Complexity

State time and space complexity, unprompted, as the last step. Not just the answer — the reasoning:

"Time: each index is pushed and popped from the deque at most once → O(n) total. Space: the deque holds at most k indices at any time → O(k)."

If you see a follow-up trade-off, mention it: "If we needed to do this on a stream where k grows dynamically, we'd need to rethink the deque's eviction logic." That kind of forward thinking is an SDE-2 signal.

---

## The 15-pattern toolkit

You're not solving novel algorithmic problems in a 45-minute interview. You're recognizing which of a small set of patterns applies, then executing. Course 13 covers all 15 in detail. The quick-reference map:

| Category | Patterns |
|----------|---------|
| **Array / String** | Two pointers, Sliding window, Prefix sum, Kadane's |
| **Linked List** | Fast/slow pointer, Reverse in-place |
| **Tree / Graph** | DFS (recursive + iterative), BFS, Topological sort |
| **Heap** | Top-K (min-heap), Merge K sorted |
| **Interval** | Sort + sweep, Union-find |
| **DP** | 1D sequence, 2D grid, Knapsack variants |
| **Other** | Binary search on answer, Monotonic stack/deque, Backtracking |

When a problem arrives, run through the categories in order. Most problems announce their pattern in the first constraint: "k largest elements" → heap; "contiguous subarray sum" → prefix sum or sliding window; "shortest path in unweighted graph" → BFS; "maximize/minimize with overlapping subproblems" → DP.

> **The trap:** you see a graph problem and reach for DFS because you practiced it most. But the problem asks for *shortest* path. BFS is correct. Recognizing the secondary constraint that disambiguates the pattern is the difference between medium and hard performance.

---

## Handling hints

When the interviewer says "what if you tracked something extra as you scanned?" or "think about what data structure keeps elements in order" — they are giving you a hint. This is not failure. Take it gracefully.

The wrong response: freeze, or ignore it and keep going.

The right response: "Okay — if I maintain a data structure that keeps elements in order as I scan, and supports O(1) access to the maximum... a deque where I enforce a decreasing invariant from back to front. That's the key. Let me update the approach."

Taking a hint well and re-integrating it quickly is itself a positive signal. It shows you can be coached. Every senior engineer has been coached. The ones who can't receive a hint cleanly are a liability in production reviews.

---

## Managing nerves and time

A 45-minute round breaks down:

```
 0:00 – 0:05  setup and problem statement
 0:05 – 0:10  clarify + examples
 0:10 – 0:15  approach discussion
 0:15 – 0:35  coding
 0:35 – 0:42  testing + edge cases
 0:42 – 0:45  complexity + questions
```

If you're at minute 35 and the code isn't working, say so: "I have two bugs I can see. Let me fix the window eviction first, since that's the core logic, and then the output indexing." Triaging under pressure is SDE-2 behavior. Silently thrashing is not.

Nerves produce silence. Silence produces a no-hire. The cure is mechanical: **when you don't know what to do next, narrate what you're thinking about doing.** "I'm trying to decide whether this should be a BFS or DFS — the shortest path requirement is pushing me toward BFS..." Narrating uncertainty is not weakness. It is transparency, and transparency is what makes you coachable.

---

## Common mistakes

**Silent coding.**

The single most common failure mode. The candidate understands the problem, writes a correct solution in 22 minutes, and the interviewer's debrief says "no hire — could not evaluate thought process, no communication." This happens. The interviewer is not watching your screen — they're watching *you*. Give them something to watch.

**Jumping to code before the approach is agreed.**

You open the editor at minute 6. The approach isn't articulated yet. The interviewer isn't sure you know what you're doing. You write 15 lines and realize you picked the wrong data structure. You start over. You've lost 12 minutes and the interviewer's confidence simultaneously.

Three minutes of approach discussion costs you nothing. Skipping it costs you everything.

**Ignoring edge cases.**

Empty input, k=0, k equals array length, all identical values, negative numbers where the algorithm assumes positives — these are not cruel tricks. They are real inputs. Production code sees them. At SDE-2 level, you are expected to generate edge cases yourself, not wait to be prompted.

**Defending a wrong approach.**

When the interviewer says "I think there might be an issue with that case," they are not asking for a debate. They are saving you. Say "good catch, let me trace through it" and find the bug. Arguing that your code is correct when it isn't is a strong negative signal.

**Writing overly clever code.**

Python one-liners that abuse comprehension nesting, JavaScript ternaries stacked four deep, C++ pointer arithmetic where a plain index would do. The interviewer needs to follow your code in real time. Unreadable code that happens to be correct is penalized because it signals you don't think about the reader.

---

## Checkpoint

You're ready for the coding challenges when you can, without looking anything up:

1. Name the six steps of the communication loop in order.
2. State what you say at minute 3 when you see a brute-force solution and suspect there's a better one.
3. Explain why taking a hint gracefully is a positive signal, not a failure.
4. Name the pattern that applies when the problem asks for the k largest elements.
5. Name the pattern that applies when the problem asks for the shortest path in an unweighted graph.
6. Describe what you do at minute 35 if two bugs are still open.
7. State the single most common failure mode in the coding round and why it causes a no-hire from a correct solution.

➡ Next: **The System Design Round** — driving the conversation, articulating trade-offs, and the specific ways the SDE-2 depth expectation differs from SDE-1.
