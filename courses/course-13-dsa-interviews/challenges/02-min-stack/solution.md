# Solution — Min Stack

The trick: maintain an **auxiliary "min stack"** in parallel with the main stack. Every element pushed carries with it the minimum value *at that depth*.

```python
class MinStack:
    def __init__(self):
        self._stack: list = []    # stores (value, min_at_this_depth)

    def push(self, val: int) -> None:
        current_min = val if not self._stack else min(val, self._stack[-1][1])
        self._stack.append((val, current_min))

    def pop(self) -> None:
        self._stack.pop()

    def top(self) -> int:
        return self._stack[-1][0]

    def getMin(self) -> int:
        return self._stack[-1][1]
```

## Why it works

Each tuple `(value, min_so_far)` encodes the global minimum of the stack *as it was when this element was pushed*. When you pop the element, you also discard its min snapshot — automatically restoring the minimum to whatever was at the element below.

There is no need to scan. `getMin` is a single index into the top of the stack.

**Why doesn't `pop` break the minimum?**
Because the element being popped was on top of all other elements — nothing below it changed while it was there. The element beneath it still holds the correct minimum for *its* depth.

## Complexity

| | Bound | Why |
|---|---|---|
| Time | O(1) all operations | Single list append/pop/index |
| Space | O(n) | One tuple per pushed element |

## Common mistakes

| Mistake | Symptom | Fix |
|---------|---------|-----|
| Storing only values, not min snapshots | `getMin` after a pop returns a stale or wrong value | Store `(val, min_at_depth)` pairs |
| Using `min(self._min_stack)` in `getMin` | O(n) scan — the original bug | Read `self._stack[-1][1]` directly |
| Separate lists for values and mins but not keeping them in sync | `getMin` returns wrong value after interleaved push/pop | Use one paired list or push/pop both lists together |
| Forgetting to handle the empty-stack case in `push` | `min(val, self._stack[-1][1])` crashes on first push | Guard with `if not self._stack` |

> **War story.** I used a separate `_min_stack` (two independent lists) in a phone screen. It worked for 90% of tests but one test failed: `push(2), push(2), pop(), getMin()` — expected 2, got something wrong. My `_min_stack` only pushed when the new value was *strictly less than* the current min, so the second `push(2)` didn't push onto `_min_stack`. When I popped the first `2` from the main stack, I also popped `_min_stack` — leaving it empty. Fix: push onto `_min_stack` whenever the new value is `≤` the current min (not strictly `<`), so duplicates are tracked correctly. Or simpler: just store the snapshot per element as shown above and the problem disappears entirely.

## Variant: two separate stacks

Some solutions maintain `self._stack` (values) and `self._min_stack` (running minimums separately):

```python
def push(self, val):
    self._stack.append(val)
    if not self._min_stack or val <= self._min_stack[-1]:
        self._min_stack.append(val)

def pop(self):
    val = self._stack.pop()
    if val == self._min_stack[-1]:
        self._min_stack.pop()

def getMin(self):
    return self._min_stack[-1]
```

This uses slightly less space in cases where the minimum rarely changes, but the `<=` (not `<`) condition is a subtle correctness requirement on duplicate minimums — the paired-tuple approach is simpler to reason about.

## Apply and verify

```bash
cd ~/.kube-dojo-work/02-min-stack
.venv/bin/pytest tests/test_sample.py -v
bash courses/course-13-dsa-interviews/challenges/02-min-stack/verify.sh
```
