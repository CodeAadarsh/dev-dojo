#!/usr/bin/env bash
# Plants the "TDD a Feature" exercise — a stub to implement and a test file to write.
set -euo pipefail

SLUG="05-tdd-a-feature"
WORK="$HOME/.kube-dojo-work/$SLUG"
mkdir -p "$WORK"

if [ ! -f "$WORK/rules.py" ]; then
cat > "$WORK/rules.py" << 'PYEOF'
def price_after_discount(items, coupon=None):
    """Compute the final price in integer paise. See brief.md for the full spec.

    items:  list of (name, unit_price_paise, qty)
    coupon: None | "SAVE10" | "FLAT500" | (anything else -> ValueError)
    """
    # Implement me — test first! Write a failing test in test_rules.py, then
    # add the minimum code here to make it pass. Repeat rule by rule.
    raise NotImplementedError("implement price_after_discount")
PYEOF
fi

if [ ! -f "$WORK/test_rules.py" ]; then
cat > "$WORK/test_rules.py" << 'PYEOF'
from rules import price_after_discount
import pytest


# Start red: this fails until you implement the empty-cart rule.
def test_empty_cart_is_zero():
    assert price_after_discount([]) == 0


# TODO (one test, then one slice of implementation, at a time):
#   - single item, no discount
#   - bulk: total qty >= 10 applies 5% off; qty == 9 does NOT
#   - SAVE10 (with and without bulk)
#   - FLAT500 (and the clamp to 0 when it would go negative)
#   - unknown coupon -> ValueError
#   - qty < 1 -> ValueError ; negative price -> ValueError
PYEOF
fi

echo
echo "Planted into: $WORK"
echo "  rules.py       — implement price_after_discount here (TDD it)"
echo "  test_rules.py  — write your tests here, test-first"
echo
echo "One-time setup:  cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install pytest pytest-cov"
echo "Iterate:         cd $WORK && .venv/bin/pytest --cov=rules --cov-branch --cov-report=term-missing"
echo "Verify + flag:   bash courses/course-36-python-testing/challenges/$SLUG/verify.sh"
