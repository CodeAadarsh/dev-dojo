# Solution — First Assertions

A suite that pins every rule. Note the structure: one behavior per test, specific equality assertions, and `pytest.raises` for every rejection rule.

```python
# test_bank.py
import pytest
from bank import Account


# ── construction ──────────────────────────────────────────────────────────
def test_default_balance_is_zero():
    assert Account().balance == 0

def test_explicit_starting_balance():
    assert Account(100).balance == 100

def test_negative_starting_balance_rejected():
    with pytest.raises(ValueError):
        Account(-1)


# ── deposit ───────────────────────────────────────────────────────────────
def test_deposit_increases_balance_and_returns_it():
    account = Account(100)
    returned = account.deposit(50)
    assert account.balance == 150          # state changed correctly
    assert returned == 150                 # return value is the NEW balance

def test_deposit_zero_rejected():
    with pytest.raises(ValueError):
        Account(100).deposit(0)

def test_deposit_negative_rejected():
    with pytest.raises(ValueError):
        Account(100).deposit(-10)


# ── withdraw ──────────────────────────────────────────────────────────────
def test_withdraw_decreases_balance_and_returns_it():
    account = Account(100)
    returned = account.withdraw(30)
    assert account.balance == 70
    assert returned == 70                  # NEW balance, not the amount (30)

def test_withdraw_zero_rejected():
    with pytest.raises(ValueError):
        Account(100).withdraw(0)

def test_withdraw_negative_rejected():
    with pytest.raises(ValueError):
        Account(100).withdraw(-5)

def test_overdraft_rejected():
    with pytest.raises(ValueError):
        Account(50).withdraw(1000)
```

## Why each test matters (mapped to the planted bugs)

| Test | Bug it catches |
|------|----------------|
| `test_deposit_increases_balance_and_returns_it` | a deposit that decreases the balance |
| `test_overdraft_rejected` | a withdraw that allows overdrawing |
| `test_deposit_zero_rejected` | `deposit(0)` being accepted (`<=` weakened to `<`) |
| `test_withdraw_decreases_balance_and_returns_it` (the `returned == 70` line) | withdraw returning the *amount* (30) instead of the new balance (70) |
| `test_negative_starting_balance_rejected` | a constructor that accepts negative balances |

## The key lesson

The verifier is a mutation tester. The single most important line is `assert returned == 70` — a lazy test that only checked `account.balance == 70` would **miss** the `return amount` bug entirely, because the balance is still correct; only the *return value* is wrong. Vague or incomplete assertions pass on correct code and silently let bugs through. Every assertion you write should be something a plausible bug could violate.

## Hardening preview

In production, money is never a bare `int` attribute you mutate in place — it's stored as integer **paise** (to avoid float errors), mutations go through a ledger of immutable transactions, and concurrent withdrawals need locking or optimistic-concurrency checks so two withdrawals can't both pass the overdraft check. The tests you just wrote are the first line of defense that makes that refactor safe.
