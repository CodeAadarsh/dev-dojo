#!/usr/bin/env bash
# Verifier for "Dynamic Secrets Rotation".
# Writes a hidden pytest suite to a temp dir, runs it against the learner's
# credential_backend.py, and prints the flag only when every check passes.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/02-dynamic-secrets-rotation"
FLAG='KUBE{dynamic_secrets_rotate_and_expire}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ] || fail "work directory missing — run setup.sh first"
[ -f "$WORK/credential_backend.py" ] || fail "credential_backend.py not found — run setup.sh first"

if [ -f "$WORK/.venv/bin/pytest" ]; then
    PYTEST="$WORK/.venv/bin/pytest"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
else
    fail "pytest not found — activate the venv: cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install pytest"
fi

HIDDEN_DIR="$(mktemp -d)"
trap 'rm -rf "$HIDDEN_DIR"' EXIT

cat > "$HIDDEN_DIR/test_creds_hidden.py" << 'PYEOF'
import sys
import os
import time

sys.path.insert(0, os.environ["DOJO_WORK"])

import pytest
from credential_backend import CredentialBackend


def test_issued_credential_is_valid():
    cb = CredentialBackend()
    cred = cb.issue(ttl_seconds=60)
    assert cb.validate(cred["lease_id"]) is True


def test_expired_credential_is_invalid():
    cb = CredentialBackend()
    cred = cb.issue(ttl_seconds=0.05)   # 50 ms TTL
    time.sleep(0.12)
    assert cb.validate(cred["lease_id"]) is False, \
        "credential must be invalid after its TTL has passed"


def test_revoke_immediately_invalidates():
    cb = CredentialBackend()
    cred = cb.issue(ttl_seconds=60)
    cb.revoke(cred["lease_id"])
    assert cb.validate(cred["lease_id"]) is False


def test_revoke_unknown_raises():
    cb = CredentialBackend()
    with pytest.raises(Exception):
        cb.revoke("nonexistent-lease-id-xyz")


def test_rotation_new_valid_old_invalid():
    cb = CredentialBackend()
    old = cb.issue(ttl_seconds=60)
    new = cb.rotate(old["lease_id"])
    assert cb.validate(new["lease_id"]) is True, \
        "new credential must be valid immediately after rotation"
    assert cb.validate(old["lease_id"]) is False, \
        "old credential must be invalid immediately after rotation"


def test_rotation_returns_distinct_credential():
    cb = CredentialBackend()
    old = cb.issue(ttl_seconds=60)
    new = cb.rotate(old["lease_id"])
    assert new["lease_id"] != old["lease_id"]
    assert "username" in new and "password" in new


def test_unique_credentials_per_issue():
    cb = CredentialBackend()
    c1 = cb.issue(ttl_seconds=60)
    c2 = cb.issue(ttl_seconds=60)
    assert c1["lease_id"] != c2["lease_id"], "each lease_id must be unique"
    # username or password must differ — identical creds would defeat the purpose
    assert c1["username"] != c2["username"] or c1["password"] != c2["password"]


def test_cleanup_expired_removes_only_expired():
    cb = CredentialBackend()
    cb.issue(ttl_seconds=0.05)
    cb.issue(ttl_seconds=0.05)
    valid = cb.issue(ttl_seconds=60)
    time.sleep(0.12)
    removed = cb.cleanup_expired()
    assert removed == 2, f"expected 2 expired leases removed, got {removed}"
    assert cb.validate(valid["lease_id"]) is True, \
        "valid lease must survive cleanup_expired"
PYEOF

if DOJO_WORK="$WORK" "$PYTEST" "$HIDDEN_DIR/test_creds_hidden.py" -q 2>&1; then
    echo
    echo "All checks passed. Submit this flag in the platform:"
    echo
    echo "    $FLAG"
else
    fail "hidden test suite has failures — fix your implementation, run the visible tests first: cd $WORK && .venv/bin/pytest tests/ -v"
fi
