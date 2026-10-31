#!/usr/bin/env bash
# Plants the "JWT Hardening" starter project.
# Idempotent — re-running overwrites source files but leaves .venv intact.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/02-jwt-hardening"
mkdir -p "$WORK/tests"

# ── jwt_auth.py skeleton ─────────────────────────────────────────────────────
cat > "$WORK/jwt_auth.py" << 'PYEOF'
# jwt_auth.py — JWT hardening skeleton
# Mission: implement issue_jwt() and verify_jwt().
import time

SECRET_KEY = "dev-secret-do-not-use-in-production"
ALGORITHM = "HS256"
ISSUER = "kube-dojo"
AUDIENCE = "kube-dojo-api"


def issue_jwt(subject: str) -> str:
    """Issue an HS256-signed JWT for `subject`.
    Required claims: sub, iss, aud, iat, exp (+15 min).
    Return the encoded token string."""
    raise NotImplementedError("implement me")


def verify_jwt(token: str) -> dict:
    """Decode and verify `token`.
    Return the payload dict on success.
    Must raise jwt.exceptions.InvalidTokenError (or subclass) for:
      - alg:none (any capitalisation)
      - wrong or missing signature
      - expired token
      - wrong audience
    """
    raise NotImplementedError("implement me")
PYEOF

# ── visible sample test ───────────────────────────────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

cat > "$WORK/tests/test_sample.py" << 'PYEOF'
import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import jwt
import jwt_auth


def test_issue_and_verify_roundtrip():
    token = jwt_auth.issue_jwt("alice")
    payload = jwt_auth.verify_jwt(token)
    assert payload["sub"] == "alice"


def test_expired_token_rejected():
    import time
    # Manually craft an expired token to confirm rejection
    payload = {
        "sub": "alice",
        "iss": jwt_auth.ISSUER,
        "aud": jwt_auth.AUDIENCE,
        "iat": int(time.time()) - 1000,
        "exp": int(time.time()) - 500,   # already expired
    }
    expired = jwt.encode(payload, jwt_auth.SECRET_KEY, algorithm="HS256")
    try:
        jwt_auth.verify_jwt(expired)
        assert False, "should have raised"
    except jwt.exceptions.InvalidTokenError:
        pass
PYEOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : implement issue_jwt() and verify_jwt() in jwt_auth.py"
echo "                 so the harness rejects alg:none, wrong sigs, expired"
echo "                 tokens, and wrong audiences."
echo
echo "Sample tests   : cd $WORK && pytest tests/test_sample.py -v"
echo "Verify + flag  : bash courses/course-16-security-auth/challenges/02-jwt-hardening/verify.sh"
