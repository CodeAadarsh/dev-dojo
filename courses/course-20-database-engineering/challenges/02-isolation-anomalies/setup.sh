#!/usr/bin/env bash
# Plants the "Isolation Anomalies" starter project into the work directory
# and seeds the accounts table in the dojo-pg Postgres container.
# Idempotent — re-running overwrites files but does not delete .venv.
set -euo pipefail

SLUG="02-isolation-anomalies"
WORK="$HOME/.kube-dojo-work/$SLUG"
mkdir -p "$WORK/tests"

# ── seed the Postgres table ──────────────────────────────────────────────────
if ! docker ps --format '{{.Names}}' | grep -q '^dojo-pg$'; then
    echo "WARNING: dojo-pg container is not running."
    echo "  Start it with:"
    echo "  docker run -d --name dojo-pg -e POSTGRES_PASSWORD=postgres \\"
    echo "    -e POSTGRES_DB=dojo -p 5432:5432 postgres:16-alpine"
    echo "  Skipping DB seed — re-run setup.sh once the container is up."
else
    docker exec -i dojo-pg psql -U postgres -d dojo << 'SQLEOF'
DROP TABLE IF EXISTS accounts;
CREATE TABLE accounts (
    id      SERIAL PRIMARY KEY,
    owner   TEXT    NOT NULL,
    balance INTEGER NOT NULL CHECK (balance >= 0)
);
INSERT INTO accounts (owner, balance) VALUES
    ('alice', 1000),
    ('bob',    500);
SQLEOF
    echo "accounts table seeded (alice=1000, bob=500)."
fi

# ── fix.py skeleton ──────────────────────────────────────────────────────────
cat > "$WORK/fix.py" << 'PYEOF'
# fix.py — deposit function with a lost-update bug.
#
# Mission: add FOR UPDATE to the SELECT inside deposit() so that two
# concurrent calls on the same account_id serialize correctly and neither
# update is lost.
#
# Do NOT change DSN, get_balance, or any function signature.
import psycopg2
import time
from contextlib import contextmanager
from typing import Generator

DSN = "dbname=dojo user=postgres host=localhost port=5432 password=postgres"


@contextmanager
def _transaction() -> Generator:
    conn = psycopg2.connect(DSN)
    conn.autocommit = False
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def deposit(account_id: int, amount: int) -> None:
    """Add `amount` to the balance of `account_id`.

    BUG: two concurrent calls both read the same balance, add `amount`,
    and write back — one increment is silently overwritten (lost update).

    Fix: change the SELECT below to SELECT ... FOR UPDATE.
    That acquires a row-level lock so the second caller blocks until the
    first transaction commits, then reads the already-updated value.
    """
    with _transaction() as conn:
        with conn.cursor() as cur:
            # ↓ THIS LINE — change to "... FOR UPDATE" to fix the race
            cur.execute(
                "SELECT balance FROM accounts WHERE id = %s",
                (account_id,),
            )
            row = cur.fetchone()
            if row is None:
                raise ValueError(f"account {account_id} not found")
            balance = row[0]
            # intentional yield point to widen the race window in tests
            time.sleep(0.02)
            cur.execute(
                "UPDATE accounts SET balance = %s WHERE id = %s",
                (balance + amount, account_id),
            )
PYEOF

# ── visible sample tests ─────────────────────────────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

cat > "$WORK/tests/test_sample.py" << 'PYEOF'
import psycopg2
import pytest
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from fix import deposit, DSN


def _balance(account_id: int) -> int:
    conn = psycopg2.connect(DSN)
    with conn.cursor() as cur:
        cur.execute("SELECT balance FROM accounts WHERE id = %s", (account_id,))
        row = cur.fetchone()
    conn.close()
    return row[0]


def _reset(account_id: int, balance: int) -> None:
    conn = psycopg2.connect(DSN)
    conn.autocommit = True
    with conn.cursor() as cur:
        cur.execute("UPDATE accounts SET balance = %s WHERE id = %s", (balance, account_id))
    conn.close()


def test_single_deposit_adds_amount():
    _reset(1, 1000)
    deposit(1, 150)
    assert _balance(1) == 1150


def test_deposit_on_missing_account_raises():
    with pytest.raises(Exception):
        deposit(99999, 100)
PYEOF

echo
echo "Work directory   : $WORK"
echo
echo "Task             : edit deposit() in fix.py — add FOR UPDATE to the SELECT"
echo "                   to prevent the lost update under concurrent calls."
echo
echo "Prerequisites    :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate"
echo "  pip install psycopg2-binary pytest"
echo
echo "Run sample tests : cd $WORK && .venv/bin/pytest tests/test_sample.py -v"
echo "Verify + flag    : bash courses/course-20-database-engineering/challenges/$SLUG/verify.sh"
