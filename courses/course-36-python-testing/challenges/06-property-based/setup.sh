#!/usr/bin/env bash
# Plants the "Properties Outlast Examples" exercise.
set -euo pipefail

SLUG="06-property-based"
WORK="$HOME/.kube-dojo-work/$SLUG"
mkdir -p "$WORK"

cat > "$WORK/rle.py" << 'PYEOF'
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
PYEOF

if [ ! -f "$WORK/test_rle.py" ]; then
cat > "$WORK/test_rle.py" << 'PYEOF'
from hypothesis import given, strategies as st
import rle


# The round-trip property — over a DIGIT-FREE alphabet (see brief.md).
# With a small alphabet, Hypothesis naturally generates repeated runs.
@given(st.text(alphabet="abcdefghij"))
def test_round_trip(s):
    assert rle.decode(rle.encode(s)) == s


# TODO:
#   - make sure the empty string is covered (the strategy above allows it)
#   - add the count invariant: the numbers in encode(s) sum to len(s)
#     (hint: re.findall(r"\d+", rle.encode(s)) then sum the ints)
PYEOF
fi

echo
echo "Planted into: $WORK"
echo "  rle.py       — the code under test (read it; do NOT modify it)"
echo "  test_rle.py  — write your property tests here (Hypothesis required)"
echo
echo "One-time setup:  cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install pytest hypothesis"
echo "Iterate:         cd $WORK && .venv/bin/pytest -v"
echo "Verify + flag:   bash courses/course-36-python-testing/challenges/$SLUG/verify.sh"
