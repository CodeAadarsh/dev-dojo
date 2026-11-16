# Solution — TDD a Feature

## The implementation (`rules.py`)

Integer math throughout — money never touches a float.

```python
def price_after_discount(items, coupon=None):
    if coupon not in (None, "SAVE10", "FLAT500"):
        raise ValueError(f"unknown coupon: {coupon!r}")

    subtotal = 0
    total_qty = 0
    for _name, unit_price_paise, qty in items:
        if qty < 1:
            raise ValueError("qty must be >= 1")
        if unit_price_paise < 0:
            raise ValueError("price must be >= 0")
        subtotal += unit_price_paise * qty
        total_qty += qty

    amount = subtotal
    if total_qty >= 10:
        amount -= (amount * 5) // 100       # 5% bulk discount, floored

    if coupon == "SAVE10":
        amount -= (amount * 10) // 100
    elif coupon == "FLAT500":
        amount -= 50000

    if amount < 0:
        amount = 0
    return amount
```

## The tests (`test_rules.py`)

```python
from rules import price_after_discount
import pytest


def test_empty_cart_is_zero():
    assert price_after_discount([]) == 0

def test_single_item_no_discount():
    assert price_after_discount([("pen", 10000, 1)]) == 10000

def test_sums_multiple_items():
    assert price_after_discount([("a", 1000, 2), ("b", 2000, 3)]) == 8000

def test_bulk_applies_at_10():
    assert price_after_discount([("pen", 1000, 10)]) == 9500

def test_bulk_not_applied_below_10():
    assert price_after_discount([("pen", 1000, 9)]) == 9000   # both sides of the threshold

def test_save10_alone():
    assert price_after_discount([("pen", 10000, 1)], "SAVE10") == 9000

def test_save10_stacks_after_bulk():
    assert price_after_discount([("pen", 1000, 10)], "SAVE10") == 8550

def test_flat500():
    assert price_after_discount([("tv", 100000, 1)], "FLAT500") == 50000

def test_flat500_clamps_to_zero():
    assert price_after_discount([("pen", 10000, 1)], "FLAT500") == 0

def test_unknown_coupon_raises():
    with pytest.raises(ValueError):
        price_after_discount([], "HACK")

def test_zero_qty_raises():
    with pytest.raises(ValueError):
        price_after_discount([("pen", 1000, 0)])

def test_negative_price_raises():
    with pytest.raises(ValueError):
        price_after_discount([("pen", -1, 1)])
```

## Why this reaches 90% branch coverage

Branch coverage counts *both directions* of every decision. The tests exercise:

- `coupon not in (...)` → both the raise (`test_unknown_coupon_raises`) and the pass-through (every other test).
- `qty < 1` → true (`test_zero_qty_raises`) and false (all valid carts).
- `unit_price < 0` → true (`test_negative_price_raises`) and false.
- `total_qty >= 10` → true (`test_bulk_applies_at_10`) and false (`test_bulk_not_applied_below_10`) — **both sides of a boundary are what branch coverage demands**.
- `coupon == "SAVE10"` / `elif "FLAT500"` / neither → all three arms.
- `amount < 0` clamp → true (`test_flat500_clamps_to_zero`) and false.

Miss any *one side* of a branch and `--cov-branch` drops you below 90% — that's the gate doing its job: a happy-path-only suite would score ~60% and be rejected.

## The TDD lesson

If you actually went test-first — one failing test, minimum code, repeat — you never "went for coverage." Coverage was a *side effect* of specifying every rule as a test before writing the code for it. That's the whole pitch: TDD produces well-covered, well-designed code as a byproduct of the discipline, not as a chore bolted on at the end. And note what coverage still can't see — if you'd written `assert price_after_discount(...)` with no `== value`, coverage would stay 90% while proving nothing. Coverage gets you in the room; the assertions do the work.
