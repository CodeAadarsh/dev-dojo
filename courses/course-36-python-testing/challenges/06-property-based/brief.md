# Properties Outlast Examples

## The setup

Here's a run-length encoder/decoder pair. `encode("aaabb")` → `"a3b2"`; `decode("a3b2")` → `"aaabb"`. The obvious test is `assert decode(encode("aaabb")) == "aaabb"` — but a single hand-picked example catches almost nothing. The *interesting* inputs are the ones you wouldn't think to type: the empty string, a single character, a run of 10+, all-identical, alternating.

Your job: **property-based testing** with Hypothesis. Instead of examples, you state properties that must hold for *every* input, and Hypothesis generates hundreds of cases trying to break them — then shrinks any failure to a minimal reproducer. Your property tests have to be strong enough to catch every planted bug.

## The code under test

`setup.sh` plants `rle.py`:

```python
import re

def encode(s):
    if s == "":
        return ""
    out = []
    prev = s[0]
    count = 1
    for ch in s[1:]:
        if ch == prev:
            count += 1
        else:
            out.append(f"{prev}{count}")
            prev = ch
            count = 1
    out.append(f"{prev}{count}")
    return "".join(out)

def decode(code):
    out = []
    for ch, num in re.findall(r"(\D)(\d+)", code):
        out.append(ch * int(num))
    return "".join(out)
```

## The important caveat (this is a real lesson)

This encoding is only unambiguous when the input contains **no digits** — if the text had digits, `decode` couldn't tell a literal `2` from a repeat count. So the round-trip property `decode(encode(s)) == s` holds only for **digit-free strings**. Your Hypothesis strategy must generate text from a digit-free alphabet (e.g. lowercase letters). If you let Hypothesis generate arbitrary text, it will *correctly* find that the round-trip breaks on `"2"` — a true failure of the property on the real code, which would stop you from ever passing. Constrain the domain to where the property actually holds.

## The spec / properties

1. **Round-trip**: for any digit-free string `s`, `decode(encode(s)) == s`.
2. **Empty**: `encode("") == ""` and `decode("") == ""`.
3. (Optional but recommended) **Count invariant**: the total of the counts in `encode(s)` equals `len(s)`.

## Your mission — and the rules

Write tests in `test_rle.py`. You **must** use Hypothesis — `from hypothesis import given` and at least one `@given(...)` test (the verifier checks). Build:

- A `@given` round-trip test over a **digit-free** alphabet — `st.text(alphabet="abcdefghij")` or `st.text(st.characters(...))` excluding digits. Include runs: with only 10 letters available, Hypothesis will naturally produce repeats.
- Cover the empty string (via the strategy allowing `""`, or an explicit example).

The verifier runs your suite against correct `rle.py` (must pass) and against mutants with an off-by-one count, a dropped final run, and a broken decode (must fail on each — Hypothesis will find and shrink the counterexample).

## Verify & flag

```bash
bash courses/course-36-python-testing/challenges/06-property-based/setup.sh
# needs: pip install pytest hypothesis
# write tests in ~/.kube-dojo-work/06-property-based/test_rle.py
bash courses/course-36-python-testing/challenges/06-property-based/verify.sh
```
