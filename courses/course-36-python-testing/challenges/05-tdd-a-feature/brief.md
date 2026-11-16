# TDD a Feature

## The setup

This one is different. Instead of testing code someone else wrote, you'll **build the feature test-first** — the way Module 06 taught. You implement a pricing function to a precise spec *and* you write the tests. Two gates decide success:

1. A **hidden correctness suite** runs against your implementation — it must pass (your code is actually correct).
2. **Your own tests** must reach **≥ 90% branch coverage** of your implementation — proving you didn't just write code and bolt on one happy-path test.

Do it in the real TDD rhythm: write a failing test for one rule, implement the minimum to pass, repeat. By the time the behavior is complete, your coverage will already be high because every line exists to satisfy a test you wrote first.

## The feature: `price_after_discount(items, coupon=None)`

All money is in **integer paise** (₹1 = 100 paise) — never floats for money. Implement `price_after_discount` in `rules.py` to this spec exactly:

**Inputs**
- `items`: a list of `(name, unit_price_paise, qty)` tuples.
- `coupon`: `None`, `"SAVE10"`, `"FLAT500"`, or anything else.

**Rules (in this order)**
1. If `coupon` is not one of `None`, `"SAVE10"`, `"FLAT500"` → raise `ValueError`.
2. For each item: if `qty < 1` → raise `ValueError`; if `unit_price_paise < 0` → raise `ValueError`.
3. `subtotal = Σ(unit_price_paise × qty)`; `total_qty = Σ qty`.
4. **Bulk discount**: if `total_qty >= 10`, take 5% off: `amount -= (amount * 5) // 100` (integer floor).
5. **Coupon** (applied *after* bulk): `"SAVE10"` → `amount -= (amount * 10) // 100`; `"FLAT500"` → `amount -= 50000`.
6. **Clamp**: the result is never negative — if it would be below 0, return `0`.
7. Return an `int` (paise).

**Worked examples**
| items | coupon | result |
|-------|--------|--------|
| `[]` | `None` | `0` |
| `[("pen", 10000, 1)]` | `None` | `10000` |
| `[("pen", 1000, 10)]` | `None` | `9500` (5% bulk off 10000) |
| `[("pen", 10000, 1)]` | `"SAVE10"` | `9000` |
| `[("pen", 1000, 10)]` | `"SAVE10"` | `8550` (9500 then −10%) |
| `[("tv", 100000, 1)]` | `"FLAT500"` | `50000` |
| `[("pen", 10000, 1)]` | `"FLAT500"` | `0` (clamped, not −40000) |

## Your mission

Fill in `rules.py` and write `test_rules.py`. The verifier:
- runs a hidden suite against your `rules.py` (correctness),
- runs **your** `test_rules.py` with `--cov=rules --cov-branch --cov-fail-under=90` (thoroughness).

To hit 90% branch coverage you must test: each coupon kind, the unknown-coupon error, the `qty < 1` and negative-price errors, the bulk threshold (both sides of `total_qty >= 10`), and the clamp.

## Verify & flag

```bash
bash courses/course-36-python-testing/challenges/05-tdd-a-feature/setup.sh
# needs: pip install pytest pytest-cov
# implement ~/.kube-dojo-work/05-tdd-a-feature/rules.py
# write    ~/.kube-dojo-work/05-tdd-a-feature/test_rules.py
bash courses/course-36-python-testing/challenges/05-tdd-a-feature/verify.sh
```
