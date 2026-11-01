# Solution — Envelope Encryption

Complete `envelope.py` implementation. Key decisions explained below the code.

```python
import os
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.keywrap import aes_key_wrap, aes_key_unwrap
from cryptography.hazmat.backends import default_backend


def generate_dek() -> bytes:
    return os.urandom(32)


def encrypt_data(plaintext: bytes, dek: bytes) -> tuple:
    nonce = os.urandom(12)          # 96-bit nonce — the standard for AES-GCM
    aesgcm = AESGCM(dek)
    ciphertext = aesgcm.encrypt(nonce, plaintext, None)  # appends 16-byte auth tag
    return nonce, ciphertext


def decrypt_data(nonce: bytes, ciphertext_with_tag: bytes, dek: bytes) -> bytes:
    aesgcm = AESGCM(dek)
    return aesgcm.decrypt(nonce, ciphertext_with_tag, None)


def wrap_dek(dek: bytes, kek: bytes) -> bytes:
    return aes_key_wrap(kek, dek, default_backend())


def unwrap_dek(wrapped_dek: bytes, kek: bytes) -> bytes:
    return aes_key_unwrap(kek, wrapped_dek, default_backend())


def rotate_kek(wrapped_dek: bytes, old_kek: bytes, new_kek: bytes) -> bytes:
    dek = unwrap_dek(wrapped_dek, old_kek)
    return wrap_dek(dek, new_kek)
```

## Why each piece is correct

**`os.urandom(12)` for the nonce.**
AES-GCM is a stream cipher + MAC. The nonce is public — it travels with the ciphertext — but it must never repeat for a given key. A single nonce reuse with the same DEK leaks the keystream and destroys both confidentiality and the authentication tag. 12 bytes (96 bits) is the NIST-recommended size for random nonces: at 2^32 encryptions per DEK the collision probability is still below 2^{-32}. If you expect more encryptions per DEK, generate a new DEK.

**`AESGCM.encrypt` appends the authentication tag.**
The `cryptography` library's AESGCM appends the 128-bit (16-byte) auth tag to the ciphertext in one call. `decrypt` verifies the tag and raises `cryptography.exceptions.InvalidTag` on failure — this is your tamper detection, automatically.

**AES Key Wrap (RFC 3394) for wrapping the DEK.**
Key Wrap is a deterministic authenticated cipher designed specifically for wrapping cryptographic keys. Unlike AES-GCM it does not need a separate nonce — the input must be at least 128 bits and a multiple of 8 bytes (a 32-byte DEK satisfies both). The authentication is built in: `aes_key_unwrap` raises `InvalidUnwrap` if the KEK is wrong or the wrapped blob is corrupted.

**`rotate_kek` touches zero data bytes.**
This is the entire point of envelope encryption. Data can be petabytes; the number of DEKs is the number of records. Rotating the KEK is O(records), not O(data). In practice, with AWS KMS `re-encrypt`, not even the DEK plaintext ever leaves the HSM — the KMS rotates it server-side.

## Attacker's view

A threat actor who compromises a single KEK can unwrap every DEK and decrypt everything. This is why the KEK lives in a hardware security module or KMS with:
- Audit logs on every use
- IAM policies limiting which services can call `unwrap`
- Automatic rotation on a schedule

The data store only ever holds `(wrapped_DEK, nonce, ciphertext)`. Even root access to the database yields nothing without the KMS.

## Verify

```bash
cd ~/.kube-dojo-work/01-envelope-encryption
. .venv/bin/activate
pytest tests/ -v   # visible tests first
bash courses/course-31-secrets-zero-trust/challenges/01-envelope-encryption/verify.sh
```
