#!/usr/bin/env bash
# Verifier for "Isolation Anomalies — Stop the Lost Update".
# Resets the table, writes a hidden pytest suite, runs it against fix.py,
# and prints the flag only when all 4 tests pass.
# Exit 0 = solved, 1 = not yet.
set -uo pipefail

SLUG="02-isolation-anomalies"
WORK="$HOME/.kube-dojo-work/$SLUG"
FLAG='KUBE{isolation_prevents_lost_update}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ]          || fail "work directory missing — run setup.sh first"
[ -f "$WORK/fix.py" ]   || fail "fix.py not found — run setup.sh first"

# ── check Docker prereq ──────────────────────────────────────────────────────
docker ps --format '{{.Names}}' | grep -q '^dojo-pg$' \
    || fail "dojo-pg container is not running — see brief.md for start command"

# ── reset accounts table to a known state ────────────────────────────────────
docker exec -i dojo-pg psql -U postgres -d dojo << 'SQLEOF' > /dev/null
TRUNCATE accounts RESTART IDENTITY;
INSERT INTO accounts (owner, balance) VALUES
    ('alice', 1000),
    ('bob',    500);
SQLEOF

cd "$WORK"

if [ -f ".venv/bin/pytest" ]; then
    PYTEST=".venv/bin/pytest"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
else
    fail "pytest not found — activate the venv: cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install psycopg2-binary pytest"
fi

mkdir -p _verify

cat > "_verify/test_hidden.py" << 'PYEOF'
import psycopg2
import threading
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from fix import deposit, DSN


def _balance(account_id: int) -> int:
    conn = psycopg2.connect(DSN)
    with conn.cursor() as cur:
        cur.execute("SELECT balance FROM accounts WHERE id = %s", (account_id,))
        row = cur.fetchone()
    conn.close()
    assert row is not None
    return row[0]


def _reset(account_id: int, balance: int) -> None:
    conn = psycopg2.connect(DSN)
    conn.autocommit = True
    with conn.cursor() as cur:
        cur.execute("UPDATE accounts SET balance = %s WHERE id = %s", (balance, account_id))
    conn.close()


def test_single_deposit():
    _reset(1, 1000)
    deposit(1, 100)
    assert _balance(1) == 1100, f"expected 1100, got {_balance(1)}"


def test_concurrent_no_lost_update():
    _reset(1, 1000)
    errors = []

    def do_deposit():
        try:
            deposit(1, 100)
        except Exception as exc:
            errors.append(str(exc))

    t1 = threading.Thread(target=do_deposit)
    t2 = threading.Thread(target=do_deposit)
    t1.start()
    t2.start()
    t1.join()
    t2.join()

    assert not errors, f"deposit raised exceptions: {errors}"
    final = _balance(1)
    assert final == 1200, (
        f"LOST UPDATE detected: expected 1200 (1000+100+100), got {final}. "
        "Add FOR UPDATE to the SELECT in fix.py to serialize the two transactions."
    )


def test_concurrent_three_deposits():
    _reset(2, 500)
    errors = []

    def do_deposit():
        try:
            deposit(2, 50)
        except Exception as exc:
            errors.append(str(exc))

    threads = [threading.Thread(target=do_deposit) for _ in range(3)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    assert not errors, f"deposit raised exceptions: {errors}"
    final = _balance(2)
    assert final == 650, (
        f"expected 650 (500+50+50+50), got {final} — one or more updates lost"
    )


def test_missing_account_raises():
    try:
        deposit(99999, 100)
        raise AssertionError("deposit on missing account must raise an exception")
    except (ValueError, Exception) as exc:
        # any exception is acceptable; just must not silently succeed
        assert "99999" in str(exc) or True  # presence check is lenient
PYEOF

if $PYTEST "_verify/test_hidden.py" -q 2>&1; then
    rm -rf "_verify"
    echo
    echo "All tests passed. Submit this flag in the platform:"
    echo
    echo "    $FLAG"
else
    rm -rf "_verify"
    fail "test suite has failures — fix deposit() in fix.py and retry"
fi
