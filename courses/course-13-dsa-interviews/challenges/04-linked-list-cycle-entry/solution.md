# Solution — Find the Cycle Entry

The flag is `KUBE{floyd_finds_the_entry_node}`.

## The algorithm

Floyd's two-pointer approach in two phases:

**Phase 1 — detect the cycle:**

```python
slow = fast = head
while fast and fast.next:
    slow = slow.next
    fast = fast.next.next
    if slow is fast:
        break
else:
    return -1   # fast exhausted -> no cycle
```

**Phase 2 — find the entry:**

After the meeting point is found, reset one pointer to `head` and advance both at speed 1:

```python
slow = head
while slow is not fast:
    slow = slow.next
    fast = fast.next
return slow.val
```

## Why phase 2 works

Let `F` = distance from `head` to cycle entry, `C` = cycle length, `k` = distance from entry to the meeting point (measured inside the cycle). At the meeting point:

- `slow` has traveled `F + k` steps
- `fast` has traveled `F + k + mC` steps for some integer `m ≥ 1` (fast lapped slow)

Since fast travels twice as far: `2(F + k) = F + k + mC`, which simplifies to `F + k = mC`, so `F = mC - k`.

When you reset one pointer to `head` and advance both at speed 1, after `F` steps:
- The `head` pointer is at the cycle entry
- The other pointer has traveled `k + F = k + mC - k = mC` steps from the meeting point — which is exactly `mC` steps around the cycle, landing it back at the meeting point — which is `F` steps from entry... wait, that's `mC - k` more steps past entry = 0 steps past entry (mod C).

They meet at the cycle entry.

## Complete implementation

```python
class ListNode:
    def __init__(self, val: int = 0, next: "ListNode | None" = None):
        self.val = val
        self.next = next


def detect_cycle_entry(head: "ListNode | None") -> int:
    slow = fast = head
    while fast and fast.next:
        slow = slow.next
        fast = fast.next.next
        if slow is fast:
            slow = head
            while slow is not fast:
                slow = slow.next
                fast = fast.next
            return slow.val
    return -1
```

## Why O(1) space matters

The hash-set approach (`visited = set(); while node: if node in visited: return node.val; visited.add(node)`) is correct but uses O(n) space — a problem if the list has millions of nodes. The interviewer will ask for the O(1) version. Floyd's algorithm is the answer.
