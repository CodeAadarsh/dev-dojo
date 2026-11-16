# Solution — Parametrize the Edges

Three parametrized tests: valid conversions, `ValueError` cases, `TypeError` cases.

```python
# test_roman.py
import pytest
from roman import to_roman


@pytest.mark.parametrize("n, expected", [
    (1, "I"),
    (2, "II"),
    (3, "III"),
    (4, "IV"),            # subtractive — catches 'no subtractive notation'
    (6, "VI"),
    (9, "IX"),            # subtractive
    (40, "XL"),           # subtractive
    (90, "XC"),           # subtractive
    (400, "CD"),          # subtractive
    (900, "CM"),          # subtractive
    (2024, "MMXXIV"),
    (3999, "MMMCMXCIX"),  # upper boundary (valid)
], ids=["1", "2", "3", "4-IV", "6", "9-IX", "40-XL", "90-XC",
        "400-CD", "900-CM", "2024", "3999-max"])
def test_valid_conversions(n, expected):
    assert to_roman(n) == expected


@pytest.mark.parametrize("bad", [0, 4000, -1, -500], ids=["zero", "4000", "neg1", "neg500"])
def test_out_of_range_raises(bad):
    with pytest.raises(ValueError):
        to_roman(bad)


@pytest.mark.parametrize("bad", [2.5, "7", None, True, [1]],
                         ids=["float", "str", "none", "bool-True", "list"])
def test_non_int_raises(bad):
    with pytest.raises(TypeError):
        to_roman(bad)
```

## Which row catches which bug

| Case | Bug caught |
|------|------------|
| `(4, "IV")`, `(9, "IX")`, … | subtractive notation dropped (would give `"IIII"`) |
| `(3, "III")` and `(1, "I")` | off-by-one in the loop (`>` instead of `>=` loses a symbol) |
| `4000` raises | upper boundary weakened to `> 4000` |
| `0` raises | lower boundary weakened to `< 0` |
| `True` raises `TypeError` | missing `bool` guard (`True` is an `int`, would convert to `"I"`) |

## The lessons

1. **Edge enumeration is the skill.** The happy-path cases (`2 → "II"`) catch almost nothing. The *edges* — subtractive pairs, both range limits, the `True`-is-an-int trap, the off-by-one — are where every bug lives. Parametrization just makes adding each discovered edge a one-line change, so you actually add it.
2. **`True` is an `int`.** `isinstance(True, int)` is `True` in Python. A type check that forgets this converts `True → "I"` silently. A test with `True` in the `TypeError` table is the only thing that catches it — a subtle, very real-world bug.
3. **Separate tables for separate outcomes.** Valid conversions, `ValueError`s, and `TypeError`s are three different contracts; three parametrized tests keep each failure labelled (`test_non_int_raises[bool-True]`) so you know instantly what broke.
