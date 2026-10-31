#!/usr/bin/env bash
# Verifier for "JWT Hardening".
# Writes a hidden pytest suite to a temp dir and runs it against the learner's
# jwt_auth.py. Prints the flag only when all tests pass.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/02-jwt-hardening"
FLAG='KUBE{jwt_alg_none_rejected}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ] || fail "work directory missing — run setup.sh first"
[ -f "$WORK/jwt_auth.py" ] || fail "jwt_auth.py not found in $WORK — run setup.sh first"

if [ -f "$WORK/.venv/bin/pytest" ]; then
    PYTEST="$WORK/.venv/bin/pytest"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
else
    fail "pytest not found — pip install pytest pyjwt"
fi

TMPDIR_SUITE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_SUITE"' EXIT

cat > "$TMPDIR_SUITE/test_hidden_jwt.py" << 'PYEOF'
import sys, os, time, base64, json
sys.path.insert(0, os.environ["DOJO_WORK"])

import jwt
import jwt_auth


def _b64url_encode(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def _forge_alg_none(subject: str, alg_value: str) -> str:
    """Craft a token whose header declares the given alg with no signature."""
    header = _b64url_encode(json.dumps({"alg": alg_value, "typ": "JWT"}).encode())
    payload = _b64url_encode(json.dumps({
        "sub": subject,
        "iss": jwt_auth.ISSUER,
        "aud": jwt_auth.AUDIENCE,
        "iat": int(time.time()),
        "exp": int(time.time()) + 900,
    }).encode())
    return f"{header}.{payload}."


def test_valid_token_roundtrip():
    token = jwt_auth.issue_jwt("alice")
    payload = jwt_auth.verify_jwt(token)
    assert payload["sub"] == "alice", "sub claim must equal the subject passed to issue_jwt"


def test_required_claims_present():
    token = jwt_auth.issue_jwt("bob")
    payload = jwt_auth.verify_jwt(token)
    for claim in ("sub", "iss", "aud", "iat", "exp"):
        assert claim in payload, f"claim '{claim}' missing from token payload"


def test_exp_is_in_future():
    token = jwt_auth.issue_jwt("charlie")
    payload = jwt.decode(
        token,
        jwt_auth.SECRET_KEY,
        algorithms=["HS256"],
        audience=jwt_auth.AUDIENCE,
    )
    assert payload["exp"] > int(time.time()), "exp must be in the future"
    assert payload["exp"] <= int(time.time()) + 901, "exp should be ~15 min from now"


def test_alg_none_lowercase_rejected():
    token = _forge_alg_none("admin", "none")
    try:
        jwt_auth.verify_jwt(token)
        raise AssertionError("alg:none (lowercase) must be rejected")
    except (jwt.exceptions.InvalidTokenError, Exception) as e:
        if isinstance(e, AssertionError):
            raise


def test_alg_none_uppercase_rejected():
    token = _forge_alg_none("admin", "NONE")
    try:
        jwt_auth.verify_jwt(token)
        raise AssertionError("alg:NONE (uppercase) must be rejected")
    except (jwt.exceptions.InvalidTokenError, Exception) as e:
        if isinstance(e, AssertionError):
            raise


def test_alg_none_mixed_case_rejected():
    token = _forge_alg_none("admin", "None")
    try:
        jwt_auth.verify_jwt(token)
        raise AssertionError("alg:None (mixed case) must be rejected")
    except (jwt.exceptions.InvalidTokenError, Exception) as e:
        if isinstance(e, AssertionError):
            raise


def test_wrong_signature_rejected():
    token = jwt_auth.issue_jwt("dave")
    # Flip the last character in the signature segment
    parts = token.split(".")
    sig = parts[2]
    # Change last char: 'a'->'b', else 'b'->'a'
    tampered_sig = sig[:-1] + ("b" if sig[-1] != "b" else "a")
    bad_token = ".".join(parts[:2] + [tampered_sig])
    try:
        jwt_auth.verify_jwt(bad_token)
        raise AssertionError("token with wrong signature must be rejected")
    except jwt.exceptions.InvalidTokenError:
        pass


def test_expired_token_rejected():
    payload = {
        "sub": "eve",
        "iss": jwt_auth.ISSUER,
        "aud": jwt_auth.AUDIENCE,
        "iat": int(time.time()) - 1000,
        "exp": int(time.time()) - 500,
    }
    expired = jwt.encode(payload, jwt_auth.SECRET_KEY, algorithm="HS256")
    try:
        jwt_auth.verify_jwt(expired)
        raise AssertionError("expired token must be rejected")
    except jwt.exceptions.InvalidTokenError:
        pass


def test_wrong_audience_rejected():
    payload = {
        "sub": "frank",
        "iss": jwt_auth.ISSUER,
        "aud": "evil-service",
        "iat": int(time.time()),
        "exp": int(time.time()) + 900,
    }
    wrong_aud = jwt.encode(payload, jwt_auth.SECRET_KEY, algorithm="HS256")
    try:
        jwt_auth.verify_jwt(wrong_aud)
        raise AssertionError("token with wrong audience must be rejected")
    except jwt.exceptions.InvalidTokenError:
        pass


def test_iss_is_set():
    token = jwt_auth.issue_jwt("grace")
    payload = jwt_auth.verify_jwt(token)
    assert payload.get("iss") == jwt_auth.ISSUER, (
        f"iss must be {jwt_auth.ISSUER!r}, got {payload.get('iss')!r}"
    )
PYEOF

cd "$WORK"
export DOJO_WORK="$WORK"

if $PYTEST "$TMPDIR_SUITE/test_hidden_jwt.py" -q 2>&1; then
    echo
    echo "All tests passed. Submit this flag in the platform:"
    echo
    echo "    $FLAG"
else
    fail "test suite has failures — fix jwt_auth.py and retry"
fi
