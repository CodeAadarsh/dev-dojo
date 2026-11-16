#!/usr/bin/env bash
# Plants the "First Assertions" exercise into the work directory.
# Idempotent for the code-under-test; never clobbers your test file once you've started.
set -euo pipefail

SLUG="01-first-assertions"
WORK="$HOME/.kube-dojo-work/$SLUG"
mkdir -p "$WORK"

# ── code under test (safe to overwrite — it's reference material) ─────────────
cat > "$WORK/bank.py" << 'PYEOF'
class Account:
    def __init__(self, balance=0):
        if balance < 0:
            raise ValueError("initial balance cannot be negative")
        self.balance = balance

    def deposit(self, amount):
        if amount <= 0:
            raise ValueError("deposit must be positive")
        self.balance += amount
        return self.balance

    def withdraw(self, amount):
        if amount <= 0:
            raise ValueError("withdrawal must be positive")
        if amount > self.balance:
            raise ValueError("insufficient funds")
        self.balance -= amount
        return self.balance
PYEOF

# ── starter test file (only if you haven't started yet) ───────────────────────
if [ ! -f "$WORK/test_bank.py" ]; then
cat > "$WORK/test_bank.py" << 'PYEOF'
import pytest
from bank import Account


# Example — the shape of one test. Delete or keep; add your own below.
def test_deposit_increases_balance():
    # Arrange
    account = Account(100)
    # Act
    new_balance = account.deposit(50)
    # Assert
    assert account.balance == 150
    assert new_balance == 150


# TODO: add tests covering every rule in the spec:
#   - starting balances (default 0, and explicit)
#   - negative starting balance raises ValueError
#   - deposit of 0 or negative raises ValueError
#   - withdraw decreases balance AND returns the new balance
#   - withdraw of 0 or negative raises ValueError
#   - withdraw of more than the balance raises ValueError (no overdraft)
PYEOF
fi

echo
echo "Planted into: $WORK"
echo "  bank.py        — the code under test (read it; do NOT modify it)"
echo "  test_bank.py   — write your tests here"
echo
echo "One-time setup:"
echo "  cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install pytest"
echo
echo "Iterate:"
echo "  cd $WORK && .venv/bin/pytest -v"
echo
echo "Verify + get the flag:"
echo "  bash courses/course-36-python-testing/challenges/$SLUG/verify.sh"
