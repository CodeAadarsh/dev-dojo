# Solution — Secure Password Auth

## Complete `auth.py`

```python
import secrets
from typing import Optional
from argon2 import PasswordHasher
from argon2.exceptions import VerifyMismatchError

_ph = PasswordHasher()

_users: dict = {}
_sessions: dict = {}
_next_id: int = 1


def register(username: str, password: str) -> dict:
    global _next_id
    if username in _users:
        raise ValueError(f"username {username!r} already taken")
    hashed = _ph.hash(password)
    _users[username] = {"user_id": _next_id, "hash": hashed}
    uid = _next_id
    _next_id += 1
    return {"user_id": uid, "hash": hashed}


def login(username: str, password: str) -> dict:
    if username not in _users:
        raise ValueError("invalid credentials")
    try:
        _ph.verify(_users[username]["hash"], password)
    except VerifyMismatchError:
        raise ValueError("invalid credentials")
    token = secrets.token_hex(32)
    _sessions[token] = username
    return {"session_token": token}


def verify_session(token: str) -> Optional[str]:
    return _sessions.get(token)
```

## Why each piece matters

**`PasswordHasher().hash(password)` produces `$argon2id$...`.**
The `argon2-cffi` library defaults to argon2id (the winner of the Password Hashing Competition). The hash string encodes algorithm, version, memory/time/parallelism parameters, random salt, and digest — everything `verify()` needs, self-contained. You never store a separate salt column.

**`_ph.verify(hash, password)` vs `hash == ph.hash(password)`.**
Never re-hash and compare. argon2id uses a random 16-byte salt baked into the stored string; a second call to `hash()` produces a completely different string for the same password. `verify()` extracts the salt from the stored hash and re-derives internally.

**Raising `ValueError` not returning a falsy value.**
A login function that returns `None` on failure silently passes `if login(u, p):` checks when the caller forgets to test the return value. Raising forces the caller to handle the failure path explicitly.

**`secrets.token_hex(32)` gives 64 hex chars = 256 bits of entropy.**
`random.token_hex` would be predictable (seeded from time). The `secrets` module uses `os.urandom`, which is the OS CSPRNG. At 64 chars, brute-forcing a valid session token is computationally infeasible.

## Attacker's view

If an attacker dumps your users table and has the argon2id hashes, cracking one password offline requires ~1–4 GB RAM per guess attempt (the default `m=65536` parameter). A 2024 GPU cluster might manage a few hundred thousand guesses per second — orders of magnitude slower than MD5/bcrypt. A 12-character random password with symbols would survive decades of cracking. The same password stored as MD5 falls in under an hour on commodity hardware.

## Verify

```bash
cd ~/.kube-dojo-work/01-secure-password-auth
bash courses/course-16-security-auth/challenges/01-secure-password-auth/verify.sh
```
