#!/usr/bin/env bash
# Plants the "OAuth2 PKCE" starter project.
# Idempotent — re-running overwrites source files but leaves .venv intact.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/03-oauth2-pkce"
mkdir -p "$WORK/tests"

# ── pkce.py skeleton ─────────────────────────────────────────────────────────
cat > "$WORK/pkce.py" << 'PYEOF'
# pkce.py — OAuth2 PKCE skeleton
# Mission: implement the three functions below.
# Standard library only — no external packages needed.
import hashlib
import secrets
import base64


def generate_code_verifier() -> str:
    """Generate a PKCE code_verifier: cryptographically random, 43–128 chars,
    URL-safe character set per RFC 7636 §4.1.
    Hint: secrets.token_urlsafe(48) already satisfies the requirements."""
    raise NotImplementedError("implement me")


def generate_code_challenge(code_verifier: str) -> str:
    """Derive the S256 code_challenge from code_verifier per RFC 7636 §4.2:
      BASE64URL(SHA256(ASCII(code_verifier)))
    No padding — strip trailing '=' characters."""
    raise NotImplementedError("implement me")


def verify_pkce(code_verifier: str, code_challenge: str) -> bool:
    """Return True if re-deriving the challenge from code_verifier matches
    code_challenge. Return False otherwise (do not raise)."""
    raise NotImplementedError("implement me")
PYEOF

# ── visible sample test ───────────────────────────────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

cat > "$WORK/tests/test_sample.py" << 'PYEOF'
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import pkce


def test_verifier_length():
    v = pkce.generate_code_verifier()
    assert 43 <= len(v) <= 128, f"verifier length {len(v)} not in [43, 128]"


def test_challenge_verifies():
    v = pkce.generate_code_verifier()
    c = pkce.generate_code_challenge(v)
    assert pkce.verify_pkce(v, c), "verify_pkce must return True for a matching pair"


def test_mismatch_rejected():
    v = pkce.generate_code_verifier()
    c = pkce.generate_code_challenge(v)
    assert not pkce.verify_pkce("tampered_verifier_xxx", c), (
        "verify_pkce must return False when verifier does not match the challenge"
    )
PYEOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : implement generate_code_verifier(), generate_code_challenge(),"
echo "                 and verify_pkce() in pkce.py per RFC 7636 S256 method."
echo
echo "Sample tests   : cd $WORK && pytest tests/test_sample.py -v"
echo "Verify + flag  : bash courses/course-16-security-auth/challenges/03-oauth2-pkce/verify.sh"
