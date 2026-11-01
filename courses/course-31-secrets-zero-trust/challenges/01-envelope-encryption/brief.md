# Envelope Encryption

A security audit at a fintech startup flagged this comment in a code review:

> "The `ENCRYPTION_KEY` and the encrypted customer records live in the same Kubernetes Secret. If an attacker reads the Secret they have both the ciphertext and the key that decrypts it."

The engineer pushed back: "But we're encrypting the data — what else are we supposed to do?"

The answer is **envelope encryption**: the encryption key for the data (the DEK) is itself encrypted with a separate key (the KEK) that lives in a KMS or key vault. The storage layer only ever holds `(wrapped_DEK, ciphertext)` — never the raw DEK or the plaintext in the same place.

AWS KMS, GCP Cloud KMS, and HashiCorp Vault Transit all implement this pattern. This challenge strips it down to first principles.

## How it works

```
plaintext ──[AES-GCM, random DEK]──► ciphertext
                  │
          random DEK ──[AES Key Wrap, KEK from KMS]──► wrapped_DEK
```

The storage layer saves `(wrapped_DEK, ciphertext)`. The KEK never leaves the KMS. To decrypt: call KMS to unwrap the DEK, then decrypt with the DEK.

**KEK rotation** is the payoff: to rotate the KEK you re-wrap every DEK with the new KEK. The data blobs never move. With millions of records this is the difference between a one-second key rotation and a multi-hour re-encryption job.

## Prerequisites

```bash
pip install pytest cryptography
```

## What `setup.sh` plants

```
~/.kube-dojo-work/01-envelope-encryption/
├── envelope.py          # six stubbed functions — implement these
└── tests/
    ├── __init__.py
    └── test_visible.py  # basic sanity checks you can run locally
```

## Mission

Implement the six functions in `envelope.py`:

| Function | What it does |
|----------|-------------|
| `generate_dek()` | Return 32 random bytes (the DEK) |
| `encrypt_data(plaintext, dek)` | AES-256-GCM encrypt; return `(nonce, ciphertext_with_tag)` |
| `decrypt_data(nonce, ct, dek)` | Decrypt; raise `InvalidTag` if tampered |
| `wrap_dek(dek, kek)` | AES Key Wrap (RFC 3394) the DEK under the KEK |
| `unwrap_dek(wrapped_dek, kek)` | Unwrap; raise on wrong KEK |
| `rotate_kek(wrapped_dek, old_kek, new_kek)` | Re-wrap the DEK without touching the data |

The verify script runs a hidden test suite that asserts all of:

- Round-trip correctness: `decrypt(encrypt(m)) == m`
- Tamper detection: flipping a byte in the ciphertext raises `InvalidTag`
- `wrap_dek` / `unwrap_dek` round-trip
- Wrong KEK is rejected
- KEK rotation: data encrypted under the old DEK is still readable after re-wrap under the new KEK
- Old KEK cannot unwrap the new-wrapped DEK
- Every `encrypt_data` call uses a unique nonce (never repeat a nonce with the same key)

## Local test run

```bash
cd ~/.kube-dojo-work/01-envelope-encryption
python3 -m venv .venv && . .venv/bin/activate
pip install pytest cryptography
pytest tests/ -v
```

## Verify

```bash
bash courses/course-31-secrets-zero-trust/challenges/01-envelope-encryption/verify.sh
```

All hidden checks green → flag printed.

## Why this matters

The attack surface for a compromised DEK is one record. The attack surface for a compromised KEK is the entire key hierarchy — but the KEK is in a KMS that logs every access, enforces IAM, and can revoke in one API call. Without envelope encryption, compromising a single Kubernetes Secret compromises every record your service ever encrypted.
