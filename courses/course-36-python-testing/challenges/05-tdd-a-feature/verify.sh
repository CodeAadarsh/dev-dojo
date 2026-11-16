#!/usr/bin/env bash
# Verifier for "TDD a Feature".
# Gate 1: a hidden suite must pass against YOUR rules.py (correctness).
# Gate 2: YOUR test_rules.py must pass AND reach >=90% branch coverage.
set -uo pipefail

SLUG="05-tdd-a-feature"
WORK="$HOME/.kube-dojo-work/$SLUG"
FLAG='KUBE{red_green_then_refactor}'

fail() { echo "✗ $1"; exit 1; }

[ -f "$WORK/rules.py" ]      || fail "rules.py not found — run setup.sh and implement it"
[ -f "$WORK/test_rules.py" ] || fail "test_rules.py not found — run setup.sh and write your tests"

if [ -f "$WORK/.venv/bin/pytest" ]; then
    PYTEST="$WORK/.venv/bin/pytest"
    PYBIN="$WORK/.venv/bin/python"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
    PYBIN="python3"
else
    fail "pytest not found — cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install pytest pytest-cov"
fi

"$PYBIN" -c "import pytest_cov" 2>/dev/null || \
    fail "pytest-cov is not installed — cd $WORK && . .venv/bin/activate && pip install pytest-cov"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cp "$WORK/rules.py" "$TMP/rules.py"
cp "$WORK/test_rules.py" "$TMP/test_rules.py"

# ── Gate 1: hidden correctness suite against the learner's implementation ─────
cat > "$TMP/test_hidden.py" << 'PYEOF'
import pytest
from rules import price_after_discount


def test_empty():
    assert price_after_discount([]) == 0

def test_single_no_discount():
    assert price_after_discount([("pen", 10000, 1)]) == 10000

def test_multiple_items_sum():
    assert price_after_discount([("a", 1000, 2), ("b", 2000, 3)]) == 8000

def test_bulk_threshold_exactly_10():
    assert price_after_discount([("pen", 1000, 10)]) == 9500

def test_bulk_not_applied_at_9():
    assert price_after_discount([("pen", 1000, 9)]) == 9000

def test_save10_no_bulk():
    assert price_after_discount([("pen", 10000, 1)], "SAVE10") == 9000

def test_save10_with_bulk():
    assert price_after_discount([("pen", 1000, 10)], "SAVE10") == 8550

def test_flat500():
    assert price_after_discount([("tv", 100000, 1)], "FLAT500") == 50000

def test_flat500_clamped_to_zero():
    assert price_after_discount([("pen", 10000, 1)], "FLAT500") == 0

def test_unknown_coupon_raises():
    with pytest.raises(ValueError):
        price_after_discount([], "NOPE")

def test_zero_qty_raises():
    with pytest.raises(ValueError):
        price_after_discount([("pen", 1000, 0)])

def test_negative_price_raises():
    with pytest.raises(ValueError):
        price_after_discount([("pen", -1, 1)])

def test_returns_int():
    assert isinstance(price_after_discount([("pen", 1000, 10)], "SAVE10"), int)
PYEOF

rm -rf "$TMP/__pycache__"
if ! ( cd "$TMP" && PYTHONDONTWRITEBYTECODE=1 "$PYTEST" -q -p no:cacheprovider test_hidden.py >"$TMP/_hidden.txt" 2>&1 ); then
    echo "✗ Gate 1 FAILED — your implementation is not correct per the spec:"
    echo "─────────────────────────────────────────────"
    sed -n '1,50p' "$TMP/_hidden.txt"
    exit 1
fi
echo "✓ Gate 1 passed — implementation matches the spec."

# ── Gate 2: learner's own tests must pass AND hit >=90% branch coverage ───────
rm -rf "$TMP/__pycache__" "$TMP/.coverage"
if ! ( cd "$TMP" && PYTHONDONTWRITEBYTECODE=1 "$PYTEST" -q -p no:cacheprovider \
        --cov=rules --cov-branch --cov-report=term-missing --cov-fail-under=90 \
        test_rules.py >"$TMP/_cov.txt" 2>&1 ); then
    echo "✗ Gate 2 FAILED — your own tests must pass and reach >=90% branch coverage of rules.py:"
    echo "─────────────────────────────────────────────"
    sed -n '1,50p' "$TMP/_cov.txt"
    exit 1
fi
echo "✓ Gate 2 passed — your tests are thorough (>=90% branch coverage)."

echo
echo "Both gates passed — you TDD'd it. Submit this flag:"
echo
echo "    $FLAG"
