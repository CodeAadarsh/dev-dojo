#!/usr/bin/env bash
# Verifier for "First Assertions".
# Runs YOUR test suite against the correct Account and against several buggy
# versions (mutants). Your suite must PASS on the correct code and FAIL on every
# mutant. Exit 0 = solved, 1 = not yet.
set -uo pipefail

SLUG="01-first-assertions"
WORK="$HOME/.kube-dojo-work/$SLUG"
FLAG='KUBE{a_test_is_an_assertion}'

fail() { echo "✗ $1"; exit 1; }

[ -f "$WORK/test_bank.py" ] || fail "test_bank.py not found — run setup.sh and write your tests first"

if [ -f "$WORK/.venv/bin/pytest" ]; then
    PYTEST="$WORK/.venv/bin/pytest"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
else
    fail "pytest not found — cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install pytest"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cp "$WORK/test_bank.py" "$TMP/test_bank.py"

# Writes a version of bank.py into $TMP. $1 selects correct or a named mutant.
emit() {
    case "$1" in
    correct)
cat > "$TMP/bank.py" << 'PYEOF'
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
        ;;
    deposit_sign)   # deposit decreases instead of increases
cat > "$TMP/bank.py" << 'PYEOF'
class Account:
    def __init__(self, balance=0):
        if balance < 0:
            raise ValueError("initial balance cannot be negative")
        self.balance = balance
    def deposit(self, amount):
        if amount <= 0:
            raise ValueError("deposit must be positive")
        self.balance -= amount
        return self.balance
    def withdraw(self, amount):
        if amount <= 0:
            raise ValueError("withdrawal must be positive")
        if amount > self.balance:
            raise ValueError("insufficient funds")
        self.balance -= amount
        return self.balance
PYEOF
        ;;
    allow_overdraft)   # withdraw no longer rejects overdraft
cat > "$TMP/bank.py" << 'PYEOF'
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
        self.balance -= amount
        return self.balance
PYEOF
        ;;
    deposit_zero_ok)   # deposit(0) no longer rejected
cat > "$TMP/bank.py" << 'PYEOF'
class Account:
    def __init__(self, balance=0):
        if balance < 0:
            raise ValueError("initial balance cannot be negative")
        self.balance = balance
    def deposit(self, amount):
        if amount < 0:
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
        ;;
    withdraw_return)   # withdraw returns the amount, not the new balance
cat > "$TMP/bank.py" << 'PYEOF'
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
        return amount
PYEOF
        ;;
    init_no_guard)   # negative starting balance no longer rejected
cat > "$TMP/bank.py" << 'PYEOF'
class Account:
    def __init__(self, balance=0):
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
        ;;
    esac
}

# Clear any cached bytecode so a freshly-written bank.py is always recompiled
# (mutants can be byte-identical in size to the correct file, which would
# otherwise let a stale .pyc mask the change).
run() {
    rm -rf "$TMP/__pycache__"
    ( cd "$TMP" && PYTHONDONTWRITEBYTECODE=1 "$PYTEST" -q -p no:cacheprovider test_bank.py >"$TMP/_out.txt" 2>&1 )
    return $?
}

# 1. Must PASS on the correct implementation.
emit correct
if ! run; then
    echo "✗ Your tests FAIL against the correct Account. They must pass on correct code first."
    echo "─────────────────────────────────────────────"
    sed -n '1,40p' "$TMP/_out.txt"
    exit 1
fi

# 2. Must FAIL on every mutant (each must be caught by some assertion).
MUTANTS="deposit_sign:a deposit that DECREASES the balance
allow_overdraft:a withdraw that allows overdrawing past the balance
deposit_zero_ok:a deposit of 0 being accepted instead of rejected
withdraw_return:withdraw returning the amount instead of the new balance
init_no_guard:a negative starting balance being accepted"

survived=0
while IFS=: read -r name desc; do
    [ -z "$name" ] && continue
    emit "$name"
    if run; then
        echo "✗ Your suite still PASSES when the code has this bug: $desc"
        echo "  → add/strengthen an assertion that would catch it."
        survived=1
    fi
done <<< "$MUTANTS"

[ "$survived" -eq 0 ] || fail "some planted bugs slipped through — strengthen your tests and retry"

echo
echo "All checks passed — your tests catch every planted bug. Submit this flag:"
echo
echo "    $FLAG"
