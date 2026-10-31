# Secure Password Auth

A code review on your team's new auth service flagged this line in `users.py`:

```python
_users[username] = {"password": password, "user_id": _next_id}
```

Plaintext passwords in a dict. The reviewer added: *"If this DB ever leaks, every user's password is exposed verbatim. Use argon2id — we have the library. Don't merge until this is fixed."*

## Context

`setup.sh` plants a starter module and a visible sample test in your work directory:

```
~/.kube-dojo-work/01-secure-password-auth/
├── auth.py          # register/login/verify_session stubs
└── tests/
    └── test_sample.py  # shows expected API; does NOT cover the full verifier suite
```

## Prerequisites

```bash
pip install pytest argon2-cffi pyjwt pyotp
```

## Mission

Implement three functions in `auth.py`:

| Function | Signature | Behaviour |
|----------|-----------|-----------|
| `register` | `(username: str, password: str) -> dict` | Hash the password with **argon2id**, store it, return `{"user_id": int, "hash": str}`. Raise `ValueError` if username already taken. |
| `login` | `(username: str, password: str) -> dict` | Verify the supplied password against the stored argon2id hash. On success return `{"session_token": str}` (mint with `secrets.token_hex(32)`). On failure raise `ValueError`. |
| `verify_session` | `(token: str) -> Optional[str]` | Already implemented — returns username for a live token or `None`. |

The hidden verifier checks all of these conditions:

1. A fresh hash must start with `$argon2id$` — not plaintext, not md5, not bcrypt.
2. `login` with the correct password must succeed and return a `session_token`.
3. `login` with a wrong password must raise `ValueError`.
4. `register` with a duplicate username must raise `ValueError`.
5. Two calls to `register` for different users must produce different hashes.
6. The stored hash must not equal `hashlib.md5(password.encode()).hexdigest()`.

## Why argon2id

MD5 and SHA-256 are fast — that is the problem. An attacker with a leaked table and a GPU can trial 10 billion MD5s per second. argon2id is memory-hard: it forces the attacker to use gigabytes of RAM per guess, reducing throughput to thousands per second and making mass-cracking economically non-viable.

`argon2-cffi` exposes the right call in two lines:

```python
from argon2 import PasswordHasher
ph = PasswordHasher()
hash = ph.hash(password)
ph.verify(hash, password)   # raises argon2.exceptions.VerifyMismatchError on mismatch
```

## Verify

```bash
bash courses/course-16-security-auth/challenges/01-secure-password-auth/verify.sh
```

All tests green → flag printed.
