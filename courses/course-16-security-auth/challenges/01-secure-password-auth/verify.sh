#!/usr/bin/env bash
# Verifier for "Secure Password Auth".
# Writes a hidden pytest suite to a temp dir, runs it against the learner's
# auth.py in the work directory, prints the flag only when all tests pass.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/01-secure-password-auth"
FLAG='KUBE{argon2id_not_plaintext}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ] || fail "work directory missing — run setup.sh first"
[ -f "$WORK/auth.py" ] || fail "auth.py not found in $WORK — run setup.sh first"

# Locate pytest
if [ -f "$WORK/.venv/bin/pytest" ]; then
    PYTEST="$WORK/.venv/bin/pytest"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
else
    fail "pytest not found — pip install pytest argon2-cffi"
fi

# Write hidden suite to a temp directory
TMPDIR_SUITE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_SUITE"' EXIT

cat > "$TMPDIR_SUITE/test_hidden_auth.py" << 'PYEOF'
import importlib, sys, os, hashlib
sys.path.insert(0, os.environ["DOJO_WORK"])

import auth

def fresh():
    importlib.reload(auth)
    return auth


def test_hash_is_argon2id():
    m = fresh()
    result = m.register("u1", "somepassword")
    h = result["hash"]
    assert h.startswith("$argon2id$"), (
        f"hash must use argon2id format (starts with '$argon2id$'), got: {h[:30]!r}"
    )


def test_hash_is_not_plaintext():
    m = fresh()
    pw = "mysecretpassword"
    result = m.register("u2", pw)
    assert result["hash"] != pw, "hash must not equal the plaintext password"


def test_hash_is_not_md5():
    m = fresh()
    pw = "anotherpassword"
    result = m.register("u3", pw)
    md5 = hashlib.md5(pw.encode()).hexdigest()
    assert result["hash"] != md5, "hash must not be a plain MD5 of the password"


def test_login_correct_password_succeeds():
    m = fresh()
    m.register("u4", "rightpass")
    result = m.login("u4", "rightpass")
    assert "session_token" in result, "login must return {'session_token': ...}"
    assert len(result["session_token"]) >= 32, "session_token should be at least 32 chars"


def test_login_wrong_password_raises():
    m = fresh()
    m.register("u5", "correctpass")
    try:
        m.login("u5", "wrongpass")
        raise AssertionError("Expected ValueError for wrong password")
    except ValueError:
        pass


def test_duplicate_register_raises():
    m = fresh()
    m.register("u6", "pass1")
    try:
        m.register("u6", "pass2")
        raise AssertionError("Expected ValueError for duplicate username")
    except ValueError:
        pass


def test_different_users_different_hashes():
    m = fresh()
    r1 = m.register("u7", "samepassword")
    r2 = m.register("u8", "samepassword")
    # argon2id uses a random salt — same password must yield different hashes
    assert r1["hash"] != r2["hash"], (
        "two register calls with the same password must produce different hashes (random salt)"
    )


def test_verify_session_returns_username():
    m = fresh()
    m.register("u9", "pw9")
    result = m.login("u9", "pw9")
    token = result["session_token"]
    assert m.verify_session(token) == "u9"


def test_verify_session_unknown_token_returns_none():
    m = fresh()
    assert m.verify_session("does-not-exist") is None
PYEOF

cd "$WORK"
export DOJO_WORK="$WORK"

if $PYTEST "$TMPDIR_SUITE/test_hidden_auth.py" -q 2>&1; then
    echo
    echo "All tests passed. Submit this flag in the platform:"
    echo
    echo "    $FLAG"
else
    fail "test suite has failures — fix auth.py and retry"
fi
