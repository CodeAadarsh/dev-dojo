#!/usr/bin/env bash
# Verifier for "Envelope Encryption".
# Writes a hidden pytest suite to a temp dir, runs it against the learner's
# envelope.py, and prints the flag only when every check passes.
set -uo pipefail

WORK="$HOME/.kube-dojo-work/01-envelope-encryption"
FLAG='KUBE{envelope_encryption_wrap_the_key_not_the_data}'

fail() { echo "✗ $1"; exit 1; }

[ -d "$WORK" ] || fail "work directory missing — run setup.sh first"
[ -f "$WORK/envelope.py" ] || fail "envelope.py not found — run setup.sh first"

if [ -f "$WORK/.venv/bin/pytest" ]; then
    PYTEST="$WORK/.venv/bin/pytest"
elif command -v pytest >/dev/null 2>&1; then
    PYTEST="pytest"
else
    fail "pytest not found — activate the venv: cd $WORK && python3 -m venv .venv && . .venv/bin/activate && pip install pytest cryptography"
fi

HIDDEN_DIR="$(mktemp -d)"
trap 'rm -rf "$HIDDEN_DIR"' EXIT

cat > "$HIDDEN_DIR/test_envelope_hidden.py" << 'PYEOF'
import sys
import os
sys.path.insert(0, os.environ["DOJO_WORK"])

import pytest

from envelope import (
    generate_dek,
    encrypt_data,
    decrypt_data,
    wrap_dek,
    unwrap_dek,
    rotate_kek,
)


def test_dek_is_32_bytes():
    dek = generate_dek()
    assert len(dek) == 32, "generate_dek must return 32 bytes (AES-256)"


def test_round_trip():
    dek = generate_dek()
    plaintext = b"top secret: launch codes"
    nonce, ct = encrypt_data(plaintext, dek)
    assert decrypt_data(nonce, ct, dek) == plaintext


def test_tamper_detection():
    from cryptography.exceptions import InvalidTag
    dek = generate_dek()
    nonce, ct = encrypt_data(b"integrity protected payload", dek)
    tampered = ct[:-1] + bytes([ct[-1] ^ 0xFF])
    with pytest.raises(InvalidTag):
        decrypt_data(nonce, tampered, dek)


def test_wrap_unwrap_roundtrip():
    kek = os.urandom(32)
    dek = generate_dek()
    wrapped = wrap_dek(dek, kek)
    assert wrapped != dek, "wrapped DEK must differ from the raw DEK"
    assert unwrap_dek(wrapped, kek) == dek


def test_wrong_kek_rejected():
    kek = os.urandom(32)
    wrong_kek = os.urandom(32)
    dek = generate_dek()
    wrapped = wrap_dek(dek, kek)
    with pytest.raises(Exception):
        unwrap_dek(wrapped, wrong_kek)


def test_rotation_keeps_data_readable():
    old_kek = os.urandom(32)
    new_kek = os.urandom(32)
    dek = generate_dek()
    plaintext = b"confidential ledger entry"
    nonce, ct = encrypt_data(plaintext, dek)
    wrapped = wrap_dek(dek, old_kek)

    new_wrapped = rotate_kek(wrapped, old_kek, new_kek)

    recovered_dek = unwrap_dek(new_wrapped, new_kek)
    assert decrypt_data(nonce, ct, recovered_dek) == plaintext, \
        "data must still decrypt after KEK rotation"


def test_rotation_old_kek_rejected():
    old_kek = os.urandom(32)
    new_kek = os.urandom(32)
    dek = generate_dek()
    wrapped = wrap_dek(dek, old_kek)
    new_wrapped = rotate_kek(wrapped, old_kek, new_kek)
    with pytest.raises(Exception):
        unwrap_dek(new_wrapped, old_kek)


def test_unique_nonces():
    dek = generate_dek()
    nonce1, _ = encrypt_data(b"same plaintext", dek)
    nonce2, _ = encrypt_data(b"same plaintext", dek)
    assert nonce1 != nonce2, \
        "each encrypt_data call must use a unique nonce — reusing a nonce with AES-GCM destroys security"
PYEOF

if DOJO_WORK="$WORK" "$PYTEST" "$HIDDEN_DIR/test_envelope_hidden.py" -q 2>&1; then
    echo
    echo "All checks passed. Submit this flag in the platform:"
    echo
    echo "    $FLAG"
else
    fail "hidden test suite has failures — fix your implementation, run the visible tests first: cd $WORK && .venv/bin/pytest tests/ -v"
fi
