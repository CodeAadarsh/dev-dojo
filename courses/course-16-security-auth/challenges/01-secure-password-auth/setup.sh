#!/usr/bin/env bash
# Plants the "Secure Password Auth" starter project.
# Idempotent — re-running overwrites source files but leaves .venv intact.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/01-secure-password-auth"
mkdir -p "$WORK/tests"

# ── auth.py skeleton ─────────────────────────────────────────────────────────
cat > "$WORK/auth.py" << 'PYEOF'
# auth.py — secure password auth skeleton
# Mission: implement register() and login() using argon2id hashing.
# verify_session() is already done — do not modify it.
import secrets
from typing import Optional

_users: dict = {}      # { username: {"user_id": int, "hash": str} }
_sessions: dict = {}   # { token: username }
_next_id: int = 1


def register(username: str, password: str) -> dict:
    """Hash password with argon2id and store it.
    Return {"user_id": int, "hash": str}.
    Raise ValueError if username already exists."""
    raise NotImplementedError("implement me")


def login(username: str, password: str) -> dict:
    """Verify password against the stored argon2id hash.
    On success mint a session token (secrets.token_hex(32)) and
    return {"session_token": str}.
    On failure raise ValueError."""
    raise NotImplementedError("implement me")


def verify_session(token: str) -> Optional[str]:
    """Return the username for a valid session token, or None."""
    return _sessions.get(token)
PYEOF

# ── visible sample test ───────────────────────────────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

cat > "$WORK/tests/test_sample.py" << 'PYEOF'
# Visible sample — shows the expected API surface.
# The actual verifier runs a separate, more thorough suite.
import importlib, sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import auth
# Reset module state between tests by reloading
def fresh():
    importlib.reload(auth)
    return auth


def test_register_returns_hash():
    m = fresh()
    result = m.register("alice", "hunter2")
    assert "hash" in result
    assert "user_id" in result


def test_login_returns_session_token():
    m = fresh()
    m.register("bob", "correct-horse")
    result = m.login("bob", "correct-horse")
    assert "session_token" in result
    assert len(result["session_token"]) > 0


def test_wrong_password_raises():
    m = fresh()
    m.register("carol", "right")
    try:
        m.login("carol", "wrong")
        assert False, "expected ValueError"
    except ValueError:
        pass
PYEOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : implement register() and login() in auth.py"
echo "                 using argon2id password hashing."
echo
echo "Sample tests   : cd $WORK && pytest tests/test_sample.py -v"
echo "Verify + flag  : bash courses/course-16-security-auth/challenges/01-secure-password-auth/verify.sh"
