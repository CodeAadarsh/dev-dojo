#!/usr/bin/env bash
# Plants the "TOTP MFA from Scratch" starter project into the work directory.
# Idempotent — re-running overwrites files but does not delete .venv.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/04-totp-mfa"
mkdir -p "$WORK/tests"

# ── totp.py skeleton ─────────────────────────────────────────────────────────
cat > "$WORK/totp.py" << 'PYEOF'
# totp.py — implement RFC 6238 TOTP
# Standard library only: hmac, hashlib, struct, base64.
# Do NOT import pyotp or any third-party OTP library.
import hmac
import hashlib
import struct
import base64


def generate(secret: str, at_time: float) -> str:
    """Return the 6-digit TOTP code for the given base32 secret at at_time (Unix seconds)."""
    # 1. Decode the base32 secret (add padding if missing).
    # 2. Compute the time step counter: int(at_time // 30), packed as big-endian uint64.
    # 3. HMAC-SHA1 the counter bytes with the decoded secret.
    # 4. Dynamic truncation: offset = digest[-1] & 0x0F
    #                         code_int = struct.unpack('>I', digest[offset:offset+4])[0] & 0x7FFFFFFF
    # 5. return str(code_int % 10**6).zfill(6)
    raise NotImplementedError("implement generate()")


def verify(secret: str, code: str, at_time: float, used_codes: set) -> bool:
    """
    Return True if code is valid for secret at at_time within a +-1 step window
    AND code has not appeared in used_codes (replay protection).
    Do NOT mutate used_codes — the caller adds accepted codes after a True return.
    """
    raise NotImplementedError("implement verify()")
PYEOF

# ── tests/test_totp_sample.py (visible sample — a subset of the hidden suite) ─
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

cat > "$WORK/tests/test_totp_sample.py" << 'PYEOF'
# Visible sample tests — a subset of the hidden verifier suite.
# These pass on a correct implementation; use them during development.
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from totp import generate, verify

# RFC 6238 Appendix B — SHA1 vectors
# Secret "12345678901234567890" base32-encoded
_RFC_SECRET = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"


def test_rfc_vector_t59():
    assert generate(_RFC_SECRET, 59.0) == "287082", \
        "RFC 6238 T=59 vector failed — check your HMAC or truncation"


def test_rfc_vector_t1111111109():
    assert generate(_RFC_SECRET, 1111111109.0) == "081804", \
        "RFC 6238 T=1111111109 vector failed"


def test_verify_current_step_valid():
    t = 1700000000.0
    code = generate(_RFC_SECRET, t)
    assert verify(_RFC_SECRET, code, t, set()) is True, \
        "current-step code must be accepted"
PYEOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : implement generate() and verify() in totp.py"
echo "                 so the full hidden pytest suite passes."
echo
echo "Prerequisites  :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate"
echo "  pip install pytest"
echo
echo "Run sample tests : cd $WORK && .venv/bin/pytest tests/ -v"
echo "Verify + flag    : bash courses/course-16-security-auth/challenges/04-totp-mfa/verify.sh"
