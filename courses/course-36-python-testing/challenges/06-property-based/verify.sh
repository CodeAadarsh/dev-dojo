#!/usr/bin/env bash
# Verifier for "Properties Outlast Examples".
set -uo pipefail

SLUG="06-property-based"
WORK="$HOME/.kube-dojo-work/$SLUG"
FLAG='KUBE{properties_outlast_examples}'

fail() { echo "✗ $1"; exit 1; }

[ -f "$WORK/test_rle.py" ] || fail "test_rle.py not found — run setup.sh and write your tests first"

grep -q "given" "$WORK/test_rle.py" || \
    fail "this challenge requires Hypothesis — use '@given(...)' with a strategy, not hand-written examples"
grep -q "hypothesis" "$WORK/test_rle.py" || \
    fail "import Hypothesis: 'from hypothesis import given, strategies as st'"

if [ -f "$WORK/.venv/bin/pytest" ]; then
    PYTEST="$WORK/.venv/bin/pytest"
    PYBIN="$WORK/.venv/bin/python"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
    PYBIN="python3"
else
    fail "pytest not found — cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install pytest hypothesis"
fi

"$PYBIN" -c "import hypothesis" 2>/dev/null || \
    fail "hypothesis is not installed — cd $WORK && . .venv/bin/activate && pip install hypothesis"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cp "$WORK/test_rle.py" "$TMP/test_rle.py"

emit() {
    case "$1" in
    correct)
cat > "$TMP/rle.py" << 'PYEOF'
import re
def encode(s):
    if s == "":
        return ""
    out = []; prev = s[0]; count = 1
    for ch in s[1:]:
        if ch == prev:
            count += 1
        else:
            out.append(f"{prev}{count}"); prev = ch; count = 1
    out.append(f"{prev}{count}")
    return "".join(out)
def decode(code):
    out = []
    for ch, num in re.findall(r"(\D)(\d+)", code):
        out.append(ch * int(num))
    return "".join(out)
PYEOF
        ;;
    count_from_zero)   # count starts at 0 -> every run is one short
cat > "$TMP/rle.py" << 'PYEOF'
import re
def encode(s):
    if s == "":
        return ""
    out = []; prev = s[0]; count = 0
    for ch in s[1:]:
        if ch == prev:
            count += 1
        else:
            out.append(f"{prev}{count}"); prev = ch; count = 0
    out.append(f"{prev}{count}")
    return "".join(out)
def decode(code):
    out = []
    for ch, num in re.findall(r"(\D)(\d+)", code):
        out.append(ch * int(num))
    return "".join(out)
PYEOF
        ;;
    drop_last_run)   # forgets to flush the final run
cat > "$TMP/rle.py" << 'PYEOF'
import re
def encode(s):
    if s == "":
        return ""
    out = []; prev = s[0]; count = 1
    for ch in s[1:]:
        if ch == prev:
            count += 1
        else:
            out.append(f"{prev}{count}"); prev = ch; count = 1
    return "".join(out)
def decode(code):
    out = []
    for ch, num in re.findall(r"(\D)(\d+)", code):
        out.append(ch * int(num))
    return "".join(out)
PYEOF
        ;;
    decode_off_by_one)   # decode repeats one too few
cat > "$TMP/rle.py" << 'PYEOF'
import re
def encode(s):
    if s == "":
        return ""
    out = []; prev = s[0]; count = 1
    for ch in s[1:]:
        if ch == prev:
            count += 1
        else:
            out.append(f"{prev}{count}"); prev = ch; count = 1
    out.append(f"{prev}{count}")
    return "".join(out)
def decode(code):
    out = []
    for ch, num in re.findall(r"(\D)(\d+)", code):
        out.append(ch * (int(num) - 1))
    return "".join(out)
PYEOF
        ;;
    esac
}

run() {
    rm -rf "$TMP/__pycache__" "$TMP/.hypothesis"
    ( cd "$TMP" && PYTHONDONTWRITEBYTECODE=1 "$PYTEST" -q -p no:cacheprovider test_rle.py >"$TMP/_out.txt" 2>&1 )
    return $?
}

emit correct
if ! run; then
    echo "✗ Your tests FAIL against the correct rle.py. They must pass on correct code first."
    echo "  (If Hypothesis found a failing digit example, constrain your strategy to a digit-free alphabet.)"
    echo "─────────────────────────────────────────────"
    sed -n '1,45p' "$TMP/_out.txt"
    exit 1
fi

MUTANTS="count_from_zero:an off-by-one where run counts start at 0 (every run one short)
drop_last_run:encode forgetting to emit the final run
decode_off_by_one:decode repeating each character one time too few"

survived=0
while IFS=: read -r name desc; do
    [ -z "$name" ] && continue
    emit "$name"
    if run; then
        echo "✗ Your property tests still PASS with this bug: $desc"
        survived=1
    fi
done <<< "$MUTANTS"

[ "$survived" -eq 0 ] || fail "a property wasn't strong enough to catch every bug — strengthen it and retry"

echo
echo "All checks passed — your properties caught every planted bug. Submit this flag:"
echo
echo "    $FLAG"
