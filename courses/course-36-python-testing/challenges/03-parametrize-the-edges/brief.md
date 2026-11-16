# Parametrize the Edges

## The setup

`to_roman(n)` converts an integer (1–3999) to a Roman numeral string. Converters like this are a minefield of edge cases: the subtractive pairs (`IV`, `IX`, `XL`, `CM`), the exact range boundaries, and off-by-one errors in the greedy loop. One hand-picked happy-path test (`to_roman(2) == "II"`) would pass against almost every broken version.

Your job: a **parametrized** test suite thorough enough that every planted bug is caught. This is the real skill parametrization teaches — not "run a test with different numbers," but *systematically enumerating the inputs where behavior changes*.

## The code under test

`setup.sh` plants `roman.py`:

```python
_VALUES = [
    (1000, "M"), (900, "CM"), (500, "D"), (400, "CD"),
    (100, "C"), (90, "XC"), (50, "L"), (40, "XL"),
    (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I"),
]

def to_roman(n):
    if not isinstance(n, int) or isinstance(n, bool):
        raise TypeError("n must be a plain int")
    if n < 1 or n > 3999:
        raise ValueError("n must be between 1 and 3999")
    out = []
    for value, symbol in _VALUES:
        while n >= value:
            out.append(symbol)
            n -= value
    return "".join(out)
```

## The spec

1. Ordinary conversions: `1→"I"`, `2→"II"`, `3→"III"`, `6→"VI"`, `2024→"MMXXIV"`.
2. **Subtractive** notation is used: `4→"IV"` (not `"IIII"`), `9→"IX"`, `40→"XL"`, `90→"XC"`, `400→"CD"`, `900→"CM"`.
3. Boundaries that are **valid**: `1→"I"` and `3999→"MMMCMXCIX"`.
4. Boundaries that are **invalid**: `0` and `4000` both raise `ValueError`. So do negatives.
5. **Type**: non-ints raise `TypeError`. Note `bool` is a subclass of `int` in Python, so `True` must raise `TypeError`, not return `"I"`.

## Your mission — and the rules

Write tests in `test_roman.py`. You **must** use `@pytest.mark.parametrize` (the verifier checks for it). Build at least:

- A table of `(n, expected)` valid conversions — include the subtractive cases and both valid boundaries.
- A table of invalid values that must raise `ValueError` (`0`, `4000`, a negative).
- A table of non-int values that must raise `TypeError` (include `True`).

Readable `ids=` are encouraged — they make failures self-documenting.

## Verify & flag

```bash
bash courses/course-36-python-testing/challenges/03-parametrize-the-edges/setup.sh
# write tests in ~/.kube-dojo-work/03-parametrize-the-edges/test_roman.py
bash courses/course-36-python-testing/challenges/03-parametrize-the-edges/verify.sh
```
