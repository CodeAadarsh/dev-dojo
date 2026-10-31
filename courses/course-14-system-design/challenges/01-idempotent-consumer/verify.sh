#!/usr/bin/env bash
# Verifier for "Idempotent Message Consumer".
# Writes a hidden pytest suite and runs it against the learner's consumer.py.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/01-idempotent-consumer"
FLAG='KUBE{idempotent_consumer_atomic_key}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ] || fail "work directory missing — run setup.sh first"
[ -f "$WORK/consumer.py" ] || fail "consumer.py not found in $WORK"

cd "$WORK"

if [ -f ".venv/bin/pytest" ]; then
    PYTEST=".venv/bin/pytest"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
else
    fail "pytest not found — activate the venv: python3 -m venv .venv && . .venv/bin/activate && pip install pytest"
fi

# Write the hidden suite at run time
HIDDEN_DIR="$WORK/.hidden_tests"
mkdir -p "$HIDDEN_DIR"

cat > "$HIDDEN_DIR/__init__.py" << 'PYEOF'
PYEOF

cat > "$HIDDEN_DIR/test_hidden.py" << 'PYEOF'
"""
Hidden verifier tests — stricter than the visible harness.
These test atomicity and constraint-based deduplication specifically.
"""
import sqlite3
import pytest
import sys
import os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from consumer import init_db, seed_account, process_message


@pytest.fixture
def conn():
    c = sqlite3.connect(":memory:")
    c.isolation_level = None
    init_db(c)
    seed_account(c, account_id=10, balance=1000)
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


def test_atomicity_no_orphan_key(conn):
    """
    If process_message raises an exception during the balance update (simulated
    by passing an account_id that does not exist), the idempotency key must NOT
    be committed to the database (no orphan key with no corresponding side effect).
    """
    msg = {"idempotency_key": "uuid-atomic-001", "account_id": 99999, "amount": 100}
    try:
        process_message(conn, msg)
    except Exception:
        pass
    assert key_count(conn, "uuid-atomic-001") == 0, (
        "If the side effect fails, the idempotency key must not be committed — "
        "both writes must be in the same transaction."
    )


def test_constraint_is_the_guard_not_select(conn):
    """
    Simulate two concurrent calls with the same key landing before either commits.
    The unique constraint must prevent double-crediting; a SELECT-then-INSERT
    pattern would fail this because both pre-checks would pass.

    We test indirectly: process the same message twice rapidly and verify
    the balance is credited exactly once.
    """
    msg = {"idempotency_key": "uuid-guard-002", "account_id": 10, "amount": 250}
    r1 = process_message(conn, msg)
    r2 = process_message(conn, msg)
    assert r1 is True
    assert r2 is False
    assert get_balance(conn, 10) == 1250, (
        "Balance must be credited exactly once regardless of duplicate calls."
    )
    assert key_count(conn, "uuid-guard-002") == 1


def test_multiple_distinct_messages_all_apply(conn):
    """All distinct messages are processed and their combined effect is correct."""
    messages = [
        {"idempotency_key": f"uuid-multi-{i}", "account_id": 10, "amount": 100}
        for i in range(5)
    ]
    for msg in messages:
        assert process_message(conn, msg) is True
    assert get_balance(conn, 10) == 1500, "Five 100-paise credits on a 1000-paise balance."
PYEOF

if $PYTEST tests/ "$HIDDEN_DIR/" -q 2>&1; then
    echo
    echo "All tests passed. Submit this flag in the platform:"
    echo
    echo "    $FLAG"
else
    fail "test suite has failures — fix your implementation and retry"
fi
