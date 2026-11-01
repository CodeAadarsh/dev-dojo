#!/usr/bin/env bash
# Plants the "Envelope Encryption" skeleton into the work directory.
# Idempotent — re-running overwrites source files but does not delete .venv.
# Does not require a Kubernetes cluster.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/01-envelope-encryption"
mkdir -p "$WORK/tests"

# ── envelope.py skeleton ─────────────────────────────────────────────────────
cat > "$WORK/envelope.py" << 'PYEOF'
# envelope.py — implement the six functions below
# Allowed imports (do not add others):
#   os
#   cryptography.hazmat.primitives.ciphers.aead.AESGCM
#   cryptography.hazmat.primitives.keywrap  (aes_key_wrap, aes_key_unwrap)
#   cryptography.hazmat.backends.default_backend
import os
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.keywrap import aes_key_wrap, aes_key_unwrap
from cryptography.hazmat.backends import default_backend


def generate_dek() -> bytes:
    """Return a fresh 32-byte (256-bit) random DEK."""
    raise NotImplementedError


def encrypt_data(plaintext: bytes, dek: bytes) -> tuple:
    """
    Encrypt plaintext with dek using AES-256-GCM.
    Returns (nonce, ciphertext_with_tag).
    The nonce must be a fresh random 12-byte value every call.
    """
    raise NotImplementedError


def decrypt_data(nonce: bytes, ciphertext_with_tag: bytes, dek: bytes) -> bytes:
    """
    Decrypt ciphertext_with_tag using AES-256-GCM with the given nonce and dek.
    Raises cryptography.exceptions.InvalidTag if the ciphertext has been tampered with.
    """
    raise NotImplementedError


def wrap_dek(dek: bytes, kek: bytes) -> bytes:
    """
    Wrap (encrypt) dek with kek using AES Key Wrap (RFC 3394).
    kek must be 16, 24, or 32 bytes.
    Returns the wrapped DEK bytes.
    """
    raise NotImplementedError


def unwrap_dek(wrapped_dek: bytes, kek: bytes) -> bytes:
    """
    Unwrap (decrypt) wrapped_dek using kek.
    Raises an exception if kek is wrong (InvalidUnwrap from cryptography).
    """
    raise NotImplementedError


def rotate_kek(wrapped_dek: bytes, old_kek: bytes, new_kek: bytes) -> bytes:
    """
    Re-wrap the DEK under new_kek without touching any encrypted data.
    Returns the new wrapped DEK.
    The old_kek must be able to unwrap wrapped_dek.
    """
    raise NotImplementedError
PYEOF

# ── tests/__init__.py ────────────────────────────────────────────────────────
cat > "$WORK/tests/__init__.py" << 'PYEOF'
PYEOF

# ── tests/test_visible.py ────────────────────────────────────────────────────
cat > "$WORK/tests/test_visible.py" << 'PYEOF'
# test_visible.py — sanity checks you can run locally before the hidden verifier
import sys
import os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import pytest

from envelope import generate_dek, encrypt_data, decrypt_data, wrap_dek, unwrap_dek


def test_generate_dek_is_32_bytes():
    dek = generate_dek()
    assert isinstance(dek, bytes)
    assert len(dek) == 32, f"expected 32 bytes, got {len(dek)}"


def test_encrypt_returns_two_parts():
    dek = generate_dek()
    result = encrypt_data(b"hello dojo", dek)
    assert len(result) == 2, "encrypt_data must return a 2-tuple (nonce, ciphertext_with_tag)"


def test_round_trip():
    dek = generate_dek()
    plaintext = b"salary: everybody earns peanuts"
    nonce, ct = encrypt_data(plaintext, dek)
    assert decrypt_data(nonce, ct, dek) == plaintext


def test_wrap_unwrap_roundtrip():
    kek = os.urandom(32)
    dek = generate_dek()
    wrapped = wrap_dek(dek, kek)
    assert isinstance(wrapped, bytes)
    assert wrapped != dek
    assert unwrap_dek(wrapped, kek) == dek
PYEOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : implement the six function bodies in envelope.py"
echo
echo "Prerequisites  :"
echo "  cd $WORK"
echo "  python3 -m venv .venv && . .venv/bin/activate"
echo "  pip install pytest cryptography"
echo
echo "Run visible tests : cd $WORK && .venv/bin/pytest tests/ -v"
echo "Verify + flag     : bash courses/course-31-secrets-zero-trust/challenges/01-envelope-encryption/verify.sh"
