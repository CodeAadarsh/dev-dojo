# Solution — Properties Outlast Examples

```python
# test_rle.py
import re
from hypothesis import given, example, strategies as st
import rle


# Digit-free alphabet — a small one so runs (repeats) happen often.
letters = st.text(alphabet="abcdefghij")


@given(letters)
@example("")            # always check the empty string too
@example("a")           # minimal single char — where off-by-one bugs bite
@example("aaaaaaaaaa")  # a long run
def test_round_trip(s):
    assert rle.decode(rle.encode(s)) == s


@given(letters)
def test_counts_sum_to_length(s):
    counts = [int(n) for n in re.findall(r"\d+", rle.encode(s))]
    assert sum(counts) == len(s)


def test_empty_cases():
    assert rle.encode("") == ""
    assert rle.decode("") == ""
```

## Why properties beat examples here

| Property | Bug it catches | Minimal counterexample Hypothesis shrinks to |
|----------|----------------|-----------------------------------------------|
| round-trip | counts start at 0 (every run one short) | `"a"` → encodes to `"a0"` → decodes to `""` |
| round-trip | encode drops the final run | `"a"` → encodes to `""` → decodes to `""` |
| round-trip | decode repeats one too few | `"aa"` → `"a2"` → decodes to `"a"` |
| count invariant | any count being wrong | the counts won't sum to `len(s)` |

You didn't write `"a"`, `"aa"`, or `"aaaaaaaaaa"` as the *reason* a test fails — Hypothesis generated strings from the alphabet, hit the bug, and **shrank** the failure to the tiniest string that still breaks it. That shrunk example is the gift: `"a"` instantly tells you the bug is in single-character / off-by-one handling.

## The domain-restriction lesson

The round-trip property is **not** true for all strings — feed it `"2"` and `decode(encode("2"))` can't recover it, because the encoding is ambiguous when the text contains digits. If you'd written `@given(st.text())` (all Unicode), Hypothesis would *correctly* find `"0"` or `"2"` and fail against the **correct** code — and you'd never pass the verifier. The fix isn't to weaken the test; it's to state the property over the domain where it actually holds (digit-free text). Knowing the exact domain of a property is as important as the property itself — and property testing *forces* you to be precise about it.

## Combine, don't replace

Notice the `@example(...)` decorators. Property tests and example tests are complementary: the properties sweep the input space; the pinned examples document the cases you *know* matter (the empty string, a single char) and guarantee they're always checked, fast, right next to the random exploration.
