#!/usr/bin/env bash
# Plants the idempotent-consumer starter project into the work directory.
# Idempotent — re-running overwrites files but preserves the SQLite DB.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/01-idempotent-consumer"
mkdir -p "$WORK/tests"

# ── consumer.py skeleton ─────────────────────────────────────────────────────
cat > "$WORK/consumer.py" << 'PYEOF'
# consumer.py — idempotent message consumer
# Implement process_message so duplicate deliveries produce no duplicate effects.
import sqlite3


def init_db(conn: sqlite3.Connection) -> None:
    """Create the schema. Called once before any process_message calls."""
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS accounts (
            id      INTEGER PRIMARY KEY,
            balance INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS processed_messages (
            idempotency_key TEXT PRIMARY KEY,
            processed_at    TEXT DEFAULT (datetime('now'))
        );
    """)
    conn.commit()


def seed_account(conn: sqlite3.Connection, account_id: int, balance: int = 0) -> None:
    """Insert an account (or ignore if it already exists)."""
    conn.execute(
        "INSERT OR IGNORE INTO accounts (id, balance) VALUES (?, ?)",
        (account_id, balance),
    )
    conn.commit()


def process_message(conn: sqlite3.Connection, message: dict) -> bool:
    """
    Process a message idempotently.

    message keys:
      idempotency_key (str) — stable UUID across redeliveries
      account_id (int)      — target account
      amount (int)          — paise to credit (always positive)

    Returns True  — first delivery; balance credited, key stored.
    Returns False — duplicate delivery; no change made.

    Rules:
    - The idempotency_key INSERT and the accounts balance UPDATE MUST happen
      in the same transaction. No partial commits.
    - Use the unique constraint on processed_messages as the guard —
      do NOT use a SELECT-then-INSERT pattern (race condition).
    - Catch sqlite3.IntegrityError to detect a duplicate key.
    """
    raise NotImplementedError("implement process_message")
PYEOF

# ── visible test harness ─────────────────────────────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

cat > "$WORK/tests/test_consumer.py" << 'PYEOF'
import sqlite3
import pytest
import sys
import os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from consumer import init_db, seed_account, process_message


@pytest.fixture
def conn():
    c = sqlite3.connect(":memory:")
    c.isolation_level = None   # autocommit off; we manage transactions
    init_db(c)
    seed_account(c, account_id=1, balance=0)
    yield c
    c.close()


def get_balance(conn, account_id):
    row = conn.execute("SELECT balance FROM accounts WHERE id = ?", (account_id,)).fetchone()
    return row[0] if row else None


def key_count(conn, key):
    row = conn.execute(
        "SELECT count(*) FROM processed_messages WHERE idempotency_key = ?", (key,)
    ).fetchone()
    return row[0]


def test_first_delivery_credits_balance(conn):
    msg = {"idempotency_key": "uuid-001", "account_id": 1, "amount": 500}
    result = process_message(conn, msg)
    assert result is True, "first delivery must return True"
    assert get_balance(conn, 1) == 500, "balance must be credited"
    assert key_count(conn, "uuid-001") == 1, "key must be stored"


def test_duplicate_delivery_is_ignored(conn):
    msg = {"idempotency_key": "uuid-002", "account_id": 1, "amount": 300}
    process_message(conn, msg)
    result = process_message(conn, msg)
    assert result is False, "duplicate delivery must return False"
    assert get_balance(conn, 1) == 300, "balance must not be double-credited"
    assert key_count(conn, "uuid-002") == 1, "key must appear exactly once"


def test_different_keys_both_succeed(conn):
    msg1 = {"idempotency_key": "uuid-003", "account_id": 1, "amount": 100}
    msg2 = {"idempotency_key": "uuid-004", "account_id": 1, "amount": 200}
    assert process_message(conn, msg1) is True
    assert process_message(conn, msg2) is True
    assert get_balance(conn, 1) == 300
PYEOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : implement process_message in consumer.py so the"
echo "                 pytest harness passes (3 visible tests)."
echo "                 The verifier adds 2 additional tests for atomicity and"
echo "                 constraint-based deduplication."
echo
echo "Prerequisites  :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate"
echo "  pip install pytest"
echo
echo "Run tests      : cd $WORK && .venv/bin/pytest tests/ -v"
echo "Verify + flag  : bash courses/course-14-system-design/challenges/01-idempotent-consumer/verify.sh"
