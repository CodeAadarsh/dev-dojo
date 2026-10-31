#!/usr/bin/env bash
# Verifier for "OAuth2 PKCE".
# Writes a hidden pytest suite to a temp dir and runs it against the learner's
# pkce.py. Prints the flag only when all tests pass.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/03-oauth2-pkce"
FLAG='KUBE{pkce_s256_prevents_interception}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ] || fail "work directory missing — run setup.sh first"
[ -f "$WORK/pkce.py" ] || fail "pkce.py not found in $WORK — run setup.sh first"

if [ -f "$WORK/.venv/bin/pytest" ]; then
    PYTEST="$WORK/.venv/bin/pytest"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
else
    fail "pytest not found — pip install pytest"
fi

TMPDIR_SUITE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_SUITE"' EXIT

cat > "$TMPDIR_SUITE/test_hidden_pkce.py" << 'PYEOF'
import sys, os, hashlib, base64, re
sys.path.insert(0, os.environ["DOJO_WORK"])

import pkce


def _manual_s256(verifier: str) -> str:
    digest = hashlib.sha256(verifier.encode("ascii")).digest()
    return base64.urlsafe_b64encode(digest).rstrip(b"=").decode()


def test_verifier_minimum_length():
    v = pkce.generate_code_verifier()
    assert len(v) >= 43, (
        f"code_verifier must be at least 43 characters (RFC 7636 §4.1), got {len(v)}"
    )


def test_verifier_maximum_length():
    v = pkce.generate_code_verifier()
    assert len(v) <= 128, (
        f"code_verifier must be at most 128 characters (RFC 7636 §4.1), got {len(v)}"
    )


def test_verifier_is_random():
    v1 = pkce.generate_code_verifier()
    v2 = pkce.generate_code_verifier()
    assert v1 != v2, "two calls to generate_code_verifier() must return different values"


def test_challenge_matches_manual_s256():
    v = pkce.generate_code_verifier()
    expected = _manual_s256(v)
    actual = pkce.generate_code_challenge(v)
    assert actual == expected, (
        f"generate_code_challenge must implement BASE64URL(SHA256(ASCII(verifier)))\n"
        f"  expected: {expected!r}\n"
        f"  got:      {actual!r}"
    )


def test_challenge_no_padding():
    v = pkce.generate_code_verifier()
    c = pkce.generate_code_challenge(v)
    assert "=" not in c, "code_challenge must not contain '=' padding (RFC 7636 §4.2)"


def test_challenge_url_safe_chars():
    v = pkce.generate_code_verifier()
    c = pkce.generate_code_challenge(v)
    assert re.fullmatch(r"[A-Za-z0-9\-_]+", c), (
        f"code_challenge must use URL-safe base64 (no '+' or '/'), got: {c!r}"
    )


def test_verify_pkce_match_returns_true():
    v = pkce.generate_code_verifier()
    c = pkce.generate_code_challenge(v)
    assert pkce.verify_pkce(v, c) is True, (
        "verify_pkce must return True when challenge was derived from verifier"
    )


def test_verify_pkce_mismatch_returns_false():
    v = pkce.generate_code_verifier()
    c = pkce.generate_code_challenge(v)
    assert pkce.verify_pkce("definitely_not_the_original_verifier_xyz123", c) is False, (
        "verify_pkce must return False when verifier does not match the challenge"
    )


def test_verify_pkce_tampered_verifier_returns_false():
    v = pkce.generate_code_verifier()
    c = pkce.generate_code_challenge(v)
    tampered = v[:-1] + ("x" if v[-1] != "x" else "y")
    assert pkce.verify_pkce(tampered, c) is False, (
        "verify_pkce must return False when verifier was tampered"
    )


def test_different_verifiers_produce_different_challenges():
    v1 = pkce.generate_code_verifier()
    v2 = pkce.generate_code_verifier()
    c1 = pkce.generate_code_challenge(v1)
    c2 = pkce.generate_code_challenge(v2)
    assert c1 != c2, (
        "different verifiers must produce different challenges (SHA256 is deterministic but input-dependent)"
    )


def test_known_vector():
    # RFC 7636 Appendix B example (abridged)
    # verifier: dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk
    # challenge: E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM
    v = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    expected_c = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
    actual_c = pkce.generate_code_challenge(v)
    assert actual_c == expected_c, (
        f"RFC 7636 Appendix B known-vector failed:\n"
        f"  expected: {expected_c!r}\n"
        f"  got:      {actual_c!r}"
    )
PYEOF

cd "$WORK"
export DOJO_WORK="$WORK"

if $PYTEST "$TMPDIR_SUITE/test_hidden_pkce.py" -q 2>&1; then
    echo
    echo "All tests passed. Submit this flag in the platform:"
    echo
    echo "    $FLAG"
else
    fail "test suite has failures — fix pkce.py and retry"
fi
