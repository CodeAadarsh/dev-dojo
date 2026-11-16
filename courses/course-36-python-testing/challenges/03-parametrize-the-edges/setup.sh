#!/usr/bin/env bash
# Plants the "Parametrize the Edges" exercise.
set -euo pipefail

SLUG="03-parametrize-the-edges"
WORK="$HOME/.kube-dojo-work/$SLUG"
mkdir -p "$WORK"

cat > "$WORK/roman.py" << 'PYEOF'
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
PYEOF

if [ ! -f "$WORK/test_roman.py" ]; then
cat > "$WORK/test_roman.py" << 'PYEOF'
import pytest
from roman import to_roman


# Valid conversions — add the subtractive cases and both boundaries.
@pytest.mark.parametrize("n, expected", [
    (1, "I"),
    (2, "II"),
    # TODO: 3, 4 (IV!), 9 (IX!), 40 (XL), 90 (XC), 400 (CD), 900 (CM),
    #       2024 (MMXXIV), and 3999 (MMMCMXCIX)
], ids=["one", "two"])
def test_valid(n, expected):
    assert to_roman(n) == expected


# TODO: a parametrized test that invalid values (0, 4000, -1) raise ValueError
# TODO: a parametrized test that non-ints (and True!) raise TypeError
PYEOF
fi

echo
echo "Planted into: $WORK"
echo "  roman.py       — the code under test (read it; do NOT modify it)"
echo "  test_roman.py  — write your parametrized tests here"
echo
echo "One-time setup:  cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install pytest"
echo "Iterate:         cd $WORK && .venv/bin/pytest -v"
echo "Verify + flag:   bash courses/course-36-python-testing/challenges/$SLUG/verify.sh"
