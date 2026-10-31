# Detect Cycle in a Linked List

During a memory-leak investigation, a senior engineer points at a heap dump: *"The GC is never collecting these `Node` objects — they're keeping each other alive in a reference loop. Before I write the fix, I want a function that tells me whether a chain has a back-edge at all."*

That's this problem. It shows up in every Tier-1 loop because the O(1)-space constraint — no visited set — forces you to know Floyd's algorithm.

## Mission

Implement `has_cycle(head)` in `solution.py`.

```
head -> [A] -> [B] -> [C] -> [D] -> [B]  (cycle: D points back to B)
              returns True

head -> [A] -> [B] -> [C] -> None
              returns False
```

**Constraints**

- Number of nodes: 0 ≤ n ≤ 10,000
- Node values: −10^5 ≤ val ≤ 10^5
- `pos` (in the test harness) is the 0-based index of the node the tail connects back to; `pos = -1` means no cycle
- **Must run in O(n) time and O(1) extra space** — using a `set` to track visited nodes will fail the hidden tests (space constraint is checked by inspection but the logic tests are the gate to the flag)

## Setup

```bash
bash courses/course-13-dsa-interviews/challenges/04-detect-cycle-ll/setup.sh
```

## Verify

```bash
bash courses/course-13-dsa-interviews/challenges/04-detect-cycle-ll/verify.sh
```

All tests green → flag printed.

## Why this matters

O(1)-space two-pointer traversal (tortoise and hare) is a pattern, not a trick. The same idea drives:
- **Cycle detection in state machines** (e.g. detecting infinite retry loops in distributed systems)
- **Finding duplicates in O(1) space** (LeetCode 287)
- **Middle-of-list** problems (slow/fast — fast hits end when slow is at the midpoint)
- **Nth node from end** (lead the fast pointer by N steps)

Every interview question in the linked-list section is a variation on "keep two pointers at different speeds or different offsets."
