# Min Stack

During a production incident review, a senior engineer red-lines this code:

```python
def getMin(self):
    return min(self._data)   # O(n) scan — called on every event dispatch tick
```

> *"This runs a linear scan of the entire stack on every `getMin` call. At 50k events/second with a stack that can reach 10k depth, that's 500M comparisons per second just for this. O(1) or it doesn't ship."*

Your job: design a `MinStack` class where every operation — `push`, `pop`, `top`, and `getMin` — runs in O(1) time.

## Context

`setup.sh` plants a starter project in your work directory:

```
~/.kube-dojo-work/02-min-stack/
├── solution.py          # MinStack class skeleton; four method stubs
└── tests/
    └── test_sample.py   # visible sample tests you can run immediately
```

## Prerequisites

```bash
cd ~/.kube-dojo-work/02-min-stack
python3 -m venv .venv && . .venv/bin/activate
pip install pytest
```

## Mission

Implement the `MinStack` class in `solution.py`:

```python
class MinStack:
    def push(self, val: int) -> None: ...
    def pop(self)            -> None: ...
    def top(self)            -> int:  ...
    def getMin(self)         -> int:  ...
```

**Contract:**

| Method | Precondition | Behaviour |
|--------|-------------|-----------|
| `push(val)` | — | Push `val` onto the stack |
| `pop()` | Stack non-empty | Remove the top element |
| `top()` | Stack non-empty | Return the top element without removing it |
| `getMin()` | Stack non-empty | Return the **current minimum** of all elements on the stack |

**Constraints:**

- All four operations must run in **O(1)** time.
- `-2^31 ≤ val ≤ 2^31 - 1`
- At most 3 × 10^4 calls total in the hidden suite.
- `pop`, `top`, and `getMin` are only called when the stack is non-empty.

**Examples:**

```
push(5) → stack: [5],       min: 5
push(3) → stack: [5,3],     min: 3
push(7) → stack: [5,3,7],   min: 3
getMin  → 3
pop     → stack: [5,3],     min: 3
pop     → stack: [5],       min: 5
getMin  → 5
```

> The brief does not give away the implementation. Think: when you pop the current minimum, how do you know what the new minimum is?

## Why this matters

The min-stack pattern is the foundation of the "monotonic stack" family used in next-greater-element, largest-rectangle-in-histogram, and stock span problems. Getting O(1) `getMin` is the turning point from "I know stacks" to "I can use auxiliary state to track derived properties at no extra cost per operation." Interviewers use this problem specifically to see if you reach for that insight unprompted.

## Verify

```bash
bash courses/course-13-dsa-interviews/challenges/02-min-stack/verify.sh
```

All tests green → flag printed.
