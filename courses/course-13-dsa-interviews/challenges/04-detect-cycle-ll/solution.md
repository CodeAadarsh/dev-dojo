# Solution — Detect Cycle in a Linked List

## The algorithm: Floyd's tortoise and hare

Two pointers start at `head`. On each step:
- `slow` advances by 1 node
- `fast` advances by 2 nodes

**If there is no cycle:** `fast` reaches `None` (or `fast.next` is `None`) in O(n/2) iterations. Loop terminates; return `False`.

**If there is a cycle:** once `fast` enters the cycle, it is "lapping" `slow` at a rate of 1 node per iteration (moving 2 vs 1). They must meet in at most `cycle_length` further iterations. Return `True`.

```python
def has_cycle(head: ListNode | None) -> bool:
    slow = head
    fast = head
    while fast is not None and fast.next is not None:
        slow = slow.next
        fast = fast.next.next
        if slow is fast:
            return True
    return False
```

### Why `fast is not None and fast.next is not None`

The two guard conditions cover two different termination cases:
- `fast is not None` — `fast` hasn't walked off the end of the list (even number of nodes)
- `fast.next is not None` — `fast.next.next` won't crash (odd number of nodes)

If either fires, we've definitively left the list, so no cycle exists.

### Why `slow is fast` (identity, not equality)

Node values can repeat. `==` would give false positives for a list like `[1, 1, 1]`. We want the same *object* in memory, not equal values — use `is`.

## Time and space complexity

| | |
|---|---|
| **Time** | O(n) — at most one full traversal before the pointers either exit or meet |
| **Space** | O(1) — two pointer variables regardless of list length |

The O(1) space constraint is why the naive `visited_set` approach, while correct, is wrong for this problem. Every Tier-1 panel will ask about it.

## Common follow-up questions

**"Where does the cycle start?"** (LeetCode 142)

After the first meeting point, reset `slow` to `head` while `fast` stays at the meeting point. Advance both by 1. They meet again at the cycle entry node. The math: if the pre-cycle length is `F` and the cycle length is `C`, the meeting point is `F % C` steps into the cycle; advancing `slow` from `head` by `F` steps while `fast` covers the remaining `C - (F % C) + F % C = C` steps puts them both at the entry.

**"What if you need the cycle length?"** Once you have the meeting point, keep `fast` there and count how many steps `slow` takes to return — that's the cycle length.

## Apply and verify

```bash
cd ~/.kube-dojo-work/04-detect-cycle-ll
# replace the body of has_cycle with the solution above, then:
.venv/bin/pytest tests/ -v
bash courses/course-13-dsa-interviews/challenges/04-detect-cycle-ll/verify.sh
```
