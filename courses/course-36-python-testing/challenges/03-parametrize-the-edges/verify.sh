#!/usr/bin/env bash
# Verifier for "Parametrize the Edges".
set -uo pipefail

SLUG="03-parametrize-the-edges"
WORK="$HOME/.kube-dojo-work/$SLUG"
FLAG='KUBE{parametrize_the_edges}'

fail() { echo "✗ $1"; exit 1; }

[ -f "$WORK/test_roman.py" ] || fail "test_roman.py not found — run setup.sh and write your tests first"

grep -q "parametrize" "$WORK/test_roman.py" || \
    fail "this challenge requires @pytest.mark.parametrize — use a table of cases, not copy-pasted tests"

if [ -f "$WORK/.venv/bin/pytest" ]; then
    PYTEST="$WORK/.venv/bin/pytest"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
else
    fail "pytest not found — cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install pytest"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cp "$WORK/test_roman.py" "$TMP/test_roman.py"

emit() {
    case "$1" in
    correct)
cat > "$TMP/roman.py" << 'PYEOF'
_VALUES = [(1000,"M"),(900,"CM"),(500,"D"),(400,"CD"),(100,"C"),(90,"XC"),
           (50,"L"),(40,"XL"),(10,"X"),(9,"IX"),(5,"V"),(4,"IV"),(1,"I")]
def to_roman(n):
    if not isinstance(n, int) or isinstance(n, bool):
        raise TypeError("n must be a plain int")
    if n < 1 or n > 3999:
        raise ValueError("n must be between 1 and 3999")
    out = []
    for value, symbol in _VALUES:
        while n >= value:
            out.append(symbol); n -= value
    return "".join(out)
PYEOF
        ;;
    no_subtractive)   # drops IV/IX/XL/XC/CD/CM  -> 4 becomes "IIII"
cat > "$TMP/roman.py" << 'PYEOF'
_VALUES = [(1000,"M"),(500,"D"),(100,"C"),(50,"L"),(10,"X"),(5,"V"),(1,"I")]
def to_roman(n):
    if not isinstance(n, int) or isinstance(n, bool):
        raise TypeError("n must be a plain int")
    if n < 1 or n > 3999:
        raise ValueError("n must be between 1 and 3999")
    out = []
    for value, symbol in _VALUES:
        while n >= value:
            out.append(symbol); n -= value
    return "".join(out)
PYEOF
        ;;
    hi_boundary)   # allows 4000
cat > "$TMP/roman.py" << 'PYEOF'
_VALUES = [(1000,"M"),(900,"CM"),(500,"D"),(400,"CD"),(100,"C"),(90,"XC"),
           (50,"L"),(40,"XL"),(10,"X"),(9,"IX"),(5,"V"),(4,"IV"),(1,"I")]
def to_roman(n):
    if not isinstance(n, int) or isinstance(n, bool):
        raise TypeError("n must be a plain int")
    if n < 1 or n > 4000:
        raise ValueError("n must be between 1 and 3999")
    out = []
    for value, symbol in _VALUES:
        while n >= value:
            out.append(symbol); n -= value
    return "".join(out)
PYEOF
        ;;
    lo_boundary)   # allows 0 (and would emit "")
cat > "$TMP/roman.py" << 'PYEOF'
_VALUES = [(1000,"M"),(900,"CM"),(500,"D"),(400,"CD"),(100,"C"),(90,"XC"),
           (50,"L"),(40,"XL"),(10,"X"),(9,"IX"),(5,"V"),(4,"IV"),(1,"I")]
def to_roman(n):
    if not isinstance(n, int) or isinstance(n, bool):
        raise TypeError("n must be a plain int")
    if n < 0 or n > 3999:
        raise ValueError("n must be between 1 and 3999")
    out = []
    for value, symbol in _VALUES:
        while n >= value:
            out.append(symbol); n -= value
    return "".join(out)
PYEOF
        ;;
    off_by_one)   # while n > value instead of >=  -> loses a symbol each run
cat > "$TMP/roman.py" << 'PYEOF'
_VALUES = [(1000,"M"),(900,"CM"),(500,"D"),(400,"CD"),(100,"C"),(90,"XC"),
           (50,"L"),(40,"XL"),(10,"X"),(9,"IX"),(5,"V"),(4,"IV"),(1,"I")]
def to_roman(n):
    if not isinstance(n, int) or isinstance(n, bool):
        raise TypeError("n must be a plain int")
    if n < 1 or n > 3999:
        raise ValueError("n must be between 1 and 3999")
    out = []
    for value, symbol in _VALUES:
        while n > value:
            out.append(symbol); n -= value
    return "".join(out)
PYEOF
        ;;
    bool_accepted)   # no bool guard -> to_roman(True) returns "I"
cat > "$TMP/roman.py" << 'PYEOF'
_VALUES = [(1000,"M"),(900,"CM"),(500,"D"),(400,"CD"),(100,"C"),(90,"XC"),
           (50,"L"),(40,"XL"),(10,"X"),(9,"IX"),(5,"V"),(4,"IV"),(1,"I")]
def to_roman(n):
    if not isinstance(n, int):
        raise TypeError("n must be a plain int")
    if n < 1 or n > 3999:
        raise ValueError("n must be between 1 and 3999")
    out = []
    for value, symbol in _VALUES:
        while n >= value:
            out.append(symbol); n -= value
    return "".join(out)
PYEOF
        ;;
    esac
}

run() {
    rm -rf "$TMP/__pycache__"
    ( cd "$TMP" && PYTHONDONTWRITEBYTECODE=1 "$PYTEST" -q -p no:cacheprovider test_roman.py >"$TMP/_out.txt" 2>&1 )
    return $?
}

emit correct
if ! run; then
    echo "✗ Your tests FAIL against the correct converter. They must pass on correct code first."
    echo "─────────────────────────────────────────────"
    sed -n '1,40p' "$TMP/_out.txt"
    exit 1
fi

MUTANTS="no_subtractive:subtractive notation dropped (4 becomes IIII, 9 becomes VIIII)
hi_boundary:the value 4000 being accepted instead of raising ValueError
lo_boundary:the value 0 being accepted instead of raising ValueError
off_by_one:an off-by-one in the greedy loop (>= weakened to >)
bool_accepted:True being converted to 'I' instead of raising TypeError"

survived=0
while IFS=: read -r name desc; do
    [ -z "$name" ] && continue
    emit "$name"
    if run; then
        echo "✗ Your suite still PASSES with this bug: $desc"
        survived=1
    fi
done <<< "$MUTANTS"

[ "$survived" -eq 0 ] || fail "some edge cases are untested — add the missing parametrize rows and retry"

echo
echo "All checks passed — every edge covered. Submit this flag:"
echo
echo "    $FLAG"
