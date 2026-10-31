#!/usr/bin/env bash
# Verifier for "TOTP MFA from Scratch".
# Runs the hidden pytest suite in the work directory; prints the flag only when
# every test passes. Exit 0 = solved, 1 = not yet.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/04-totp-mfa"
FLAG='KUBE{totp_window_prevents_replay}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ] || fail "work directory missing — run setup.sh first"
[ -f "$WORK/totp.py" ] || fail "totp.py not found in $WORK"

cd "$WORK"

if [ -f ".venv/bin/pytest" ]; then
    PYTEST=".venv/bin/pytest"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
else
    fail "pytest not found — activate the venv: cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install pytest"
fi

# ── hidden test suite written inline ─────────────────────────────────────────
HIDDEN_TESTS=$(cat << 'PYEOF'
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from totp import generate, verify

_RFC_SECRET    = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"   # b"12345678901234567890"
_HELLO_SECRET  = "JBSWY3DPEHPK3PXP"                    # b"Hello!"


def test_rfc_vector_t59():
    assert generate(_RFC_SECRET, 59.0) == "287082"


def test_rfc_vector_t1111111109():
    assert generate(_RFC_SECRET, 1111111109.0) == "081804"


def test_hello_secret_t0():
    # T=0 → step 0: HMAC-SHA1(b"Hello!", \x00*8) → known value
    assert generate(_HELLO_SECRET, 0.0) == "282760"


def test_six_digit_zero_padded():
    # code must always be exactly 6 chars, zero-padded
    for t in (1.0, 31.0, 61.0, 1_000_000.0):
        code = generate(_RFC_SECRET, t)
        assert len(code) == 6, f"code length {len(code)} at t={t}"
        assert code.isdigit(), f"code not digits at t={t}"


def test_verify_current_step():
    t = 1_700_000_000.0
    code = generate(_RFC_SECRET, t)
    assert verify(_RFC_SECRET, code, t, set()) is True


def test_verify_previous_step_window():
    t = 1_700_000_000.0
    prev_code = generate(_RFC_SECRET, t - 30)
    assert verify(_RFC_SECRET, prev_code, t, set()) is True, \
        "code from step-1 must be accepted (±1 window)"


def test_verify_next_step_window():
    t = 1_700_000_000.0
    next_code = generate(_RFC_SECRET, t + 30)
    assert verify(_RFC_SECRET, next_code, t, set()) is True, \
        "code from step+1 must be accepted (±1 window)"


def test_verify_two_steps_back_rejected():
    t = 1_700_000_000.0
    old_code = generate(_RFC_SECRET, t - 60)
    assert verify(_RFC_SECRET, old_code, t, set()) is False, \
        "code from step-2 must be rejected (outside ±1 window)"


def test_verify_replay_rejected():
    t = 1_700_000_000.0
    code = generate(_RFC_SECRET, t)
    used = {code}
    assert verify(_RFC_SECRET, code, t, used) is False, \
        "replayed code must be rejected"


def test_verify_wrong_code_rejected():
    t = 1_700_000_000.0
    assert verify(_RFC_SECRET, "000000", t, set()) is False


def test_verify_does_not_mutate_used_codes():
    t = 1_700_000_000.0
    code = generate(_RFC_SECRET, t)
    used: set = set()
    verify(_RFC_SECRET, code, t, used)
    assert len(used) == 0, "verify() must not mutate used_codes — caller owns that"
PYEOF
)

HIDDEN_FILE="$WORK/tests/_hidden_totp_suite.py"
printf '%s\n' "$HIDDEN_TESTS" > "$HIDDEN_FILE"

if $PYTEST "$HIDDEN_FILE" -q 2>&1; then
    rm -f "$HIDDEN_FILE"
    echo
    echo "All TOTP tests passed. Submit this flag in the platform:"
    echo
    echo "    $FLAG"
else
    rm -f "$HIDDEN_FILE"
    fail "test suite has failures — fix your implementation and retry"
fi
