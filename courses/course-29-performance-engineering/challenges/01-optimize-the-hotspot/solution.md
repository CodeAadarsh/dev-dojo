# Solution — Optimize the Hotspot

The one-line fix — and the reasoning behind why it's provably correct:

```python
def find_common_endpoints(log_a: list, log_b: list) -> set:
    """Return the set of endpoint strings that appear in BOTH log_a and log_b."""
    return set(log_a) & set(log_b)
```

Apply and verify:

```bash
cd ~/.kube-dojo-work/01-optimize-the-hotspot
.venv/bin/pytest tests/ -v
bash courses/course-29-performance-engineering/challenges/01-optimize-the-hotspot/verify.sh
```

## Why each piece is correct

**`set(log_a)`** builds a hash set from log_a in O(n) time and O(n) space. Duplicate entries in log_a collapse — correct, because the original function also couldn't add the same endpoint twice (`result.add` is idempotent).

**`set(log_b)`** does the same for log_b in O(m).

**`&` (set intersection)** iterates the smaller set and checks each element against the larger set's hash table in O(1) per lookup. Total: O(min(n, m)) for the intersection step.

**Total: O(n + m)**, down from O(n × m). At n = m = 500 000, that's 1 000 000 operations vs 250 000 000 000 — a 250 000× speedup.

## Alternative: build one set, stream the other

If memory is tight and log_b is a large file read as a generator, you can build only one set:

```python
def find_common_endpoints(log_a: list, log_b: list) -> set:
    b_set = set(log_b)                          # O(m) space
    return {ep for ep in log_a if ep in b_set}  # O(n) time, O(1) lookup each
```

This still O(n + m) but only allocates one hash set instead of two, which matters when the inputs are multi-gigabyte log files you're streaming line by line.

## How the complexity proxy works

The verifier wraps `log_b` in a `_CountedList` that counts every element accessed (iteration, `in` operator, or index). An O(n) solution builds `set(log_b)` once — iterating it exactly `m` times. An O(n²) solution iterates it `n` times — accessing `n × m` elements. The test asserts accesses ≤ 10 × n, which O(n) passes easily and O(n²) fails by a factor of ~500.

## The general pattern: avoid list membership in a loop

Whenever you write `if x in some_list` inside a `for` loop, you have O(n²). The fix is always the same: convert the outer container to a `set` (or `dict`) once before the loop.

```python
# red flag: O(n²)
for item in collection:
    if item in another_list:     # O(n) scan each time
        ...

# fix: O(n)
lookup = set(another_list)      # O(n) once
for item in collection:
    if item in lookup:           # O(1) hash lookup
        ...
```

This pattern appears in dozens of forms: deduplication, diff computation, tag matching, allowlists, cache invalidation. Recognising it in flamegraphs (a loop inside a loop, one being a list) is a core performance engineering skill.
