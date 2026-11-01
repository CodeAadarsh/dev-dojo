#!/usr/bin/env bash
# Plants the "Dynamic Secrets Rotation" skeleton into the work directory.
# Idempotent — re-running overwrites source files but does not delete .venv.
# Does not require a Kubernetes cluster.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/02-dynamic-secrets-rotation"
mkdir -p "$WORK/tests"

# ── credential_backend.py skeleton ───────────────────────────────────────────
cat > "$WORK/credential_backend.py" << 'PYEOF'
# credential_backend.py — implement the five methods of CredentialBackend
# Simulates HashiCorp Vault's dynamic credential / lease lifecycle.
# Standard library only: time, uuid, secrets, dataclasses, typing.
import time
import uuid
import secrets
from dataclasses import dataclass, field
from typing import Dict, Optional


@dataclass
class Lease:
    lease_id: str
    username: str
    password: str
    expires_at: float           # epoch seconds
    revoked: bool = False


class CredentialBackend:
    """
    In-memory dynamic credential store.
    Mirrors the contract of HashiCorp Vault's database secrets engine.
    """

    def __init__(self):
        self._leases: Dict[str, Lease] = {}

    def issue(self, ttl_seconds: float) -> dict:
        """
        Issue a new credential with a lease.
        Returns a dict with keys: lease_id, username, password, expires_at.
        Each call must produce a unique lease_id, username, and password.
        ttl_seconds may be a float (e.g. 0.05 for 50 ms in tests).
        """
        raise NotImplementedError

    def validate(self, lease_id: str) -> bool:
        """
        Return True iff the lease exists, has not passed its TTL, and has not
        been revoked.  Return False for unknown lease_ids (do not raise).
        """
        raise NotImplementedError

    def revoke(self, lease_id: str) -> None:
        """
        Immediately invalidate the lease.
        Raises KeyError (or any exception) if lease_id is unknown.
        """
        raise NotImplementedError

    def rotate(self, lease_id: str) -> dict:
        """
        Atomically issue a new credential and revoke the old one.
        The old lease must be invalid immediately after this call.
        Returns the new credential dict (same shape as issue()).
        Raises if the lease is already invalid or unknown.
        """
        raise NotImplementedError

    def cleanup_expired(self) -> int:
        """
        Remove all leases whose TTL has passed (regardless of revoke status).
        Returns the count of leases removed.
        Valid (non-expired, non-revoked) leases must not be touched.
        """
        raise NotImplementedError
PYEOF

# ── tests/__init__.py ────────────────────────────────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

# ── tests/test_visible.py ────────────────────────────────────────────────────
cat > "$WORK/tests/test_visible.py" << 'PYEOF'
# test_visible.py — smoke checks you can run locally before the hidden verifier
import sys
import os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import pytest
from credential_backend import CredentialBackend


def test_issue_returns_required_fields():
    cb = CredentialBackend()
    cred = cb.issue(ttl_seconds=30)
    for key in ("lease_id", "username", "password", "expires_at"):
        assert key in cred, f"issue() must return {key!r} in the dict"


def test_validate_freshly_issued():
    cb = CredentialBackend()
    cred = cb.issue(ttl_seconds=30)
    assert cb.validate(cred["lease_id"]) is True


def test_validate_unknown_returns_false():
    cb = CredentialBackend()
    assert cb.validate("no-such-lease-id") is False


def test_revoke_invalidates():
    cb = CredentialBackend()
    cred = cb.issue(ttl_seconds=30)
    cb.revoke(cred["lease_id"])
    assert cb.validate(cred["lease_id"]) is False
PYEOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : implement the five methods in credential_backend.py"
echo
echo "Prerequisites  :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate"
echo "  pip install pytest"
echo
echo "Run visible tests : cd $WORK && .venv/bin/pytest tests/ -v"
echo "Verify + flag     : bash courses/course-31-secrets-zero-trust/challenges/02-dynamic-secrets-rotation/verify.sh"
