# Find the Cycle Entry

A production service runs a linked-list-backed message queue. A bug in the dequeue path occasionally creates a reference loop — the tail links back to a node mid-list instead of to `None`. The symptom is an infinite loop in the consumer. Your job is the diagnostic tool: given the head of a possibly-cyclic linked list, return the **value of the node where the cycle begins**, or `-1` if there is no cycle.

## Context

`setup.sh` plants a starter project in your work directory:

```
~/.kube-dojo-work/04-linked-list-cycle-entry/
├── solution.py       # ListNode class + stub detect_cycle_entry(head)
└── tests/
    └── test_cycle.py # eight-test harness you can run locally
```

## Prerequisites

```bash
cd ~/.kube-dojo-work/04-linked-list-cycle-entry
python3 -m venv .venv && . .venv/bin/activate
pip install pytest
```

## Mission

Implement `detect_cycle_entry(head: ListNode) -> int` in `solution.py`.

The function must return:
- The **integer value** at the entry node if a cycle exists.
- `-1` if the list has no cycle.

The harness tests these cases exactly:

| Scenario | Expected return |
|----------|----------------|
| No cycle | `-1` |
| Cycle at head (entire list is cyclic) | value at head |
| Cycle at tail-connects-to-head | value at head |
| Cycle at middle node | value at that middle node |
| Single node with self-loop | value of that node |
| Single node, no cycle | `-1` |
| Long list, cycle deep | correct entry value |
| Long list, no cycle | `-1` |

## Why this matters

`has_cycle()` returning a boolean is the easy half. Knowing *where* the cycle starts is the diagnostic signal — in a real system it maps to which node's `next` pointer was corrupted. The standard solution (Floyd's algorithm + the pointer-reset trick) is O(n) time and O(1) space — no hash set, no modifying the list.

## Verify

```bash
bash courses/course-13-dsa-interviews/challenges/04-linked-list-cycle-entry/verify.sh
```

All eight tests green → flag printed.
