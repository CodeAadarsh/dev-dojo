# Passwords & Sessions

> **Module 02 · Course 16** — The most common credential-related breach isn't a clever crypto break. It's a leaked database dump where passwords were hashed with MD5 in 2015, and half the list was cracked in eight hours with a GPU. This module builds the stack that makes that outcome impossible.

---

## Password Hashing

### Why "just hashing" is not enough

SHA-256 is a cryptographic hash. It is *not* a password hash. The distinction matters enormously.

```
SHA-256("hunter2")     → 6857b16a72e 7d4...  (< 1 µs, repeatable, GPU-parallelizable)
argon2id("hunter2", …) → $argon2id$v=19$...  (300 ms, memory-hard, per-password unique)
```

A SHA-256 lookup table for every English word takes minutes to build and covers millions of passwords. An argon2id output cannot be precomputed for all inputs because it's *intentionally slow* and *memory-hard* — it needs to hold a large memory buffer during computation, which prevents GPU-scale parallelism.

### The modern hierarchy

| Algorithm | Use | Notes |
|-----------|-----|-------|
| **argon2id** | New systems, all modern languages | Winner of Password Hashing Competition (2015). Tune `m`, `t`, `p` to your hardware. |
| **bcrypt** | Legacy systems still on bcrypt | Max 72-byte input (silently truncates), blowfish internals, no parallelism concern. Still fine. |
| **scrypt** | Acceptable | Awkward parameter surface; argon2id is preferred for new code. |
| **PBKDF2-SHA256** | FIPS compliance | Acceptable only when argon2 is unavailable. GPU-parallelizable — compensate with very high iterations (600k+). |
| **MD5 / SHA1 / SHA256** | **Never.** | These are fast hashes. No salting, GPU-friendly. |

### Salts

A salt is a random value stored alongside the hash that prevents precomputed attacks.

```
without salt:
  hash("hunter2") = X  →  lookup table says X == "hunter2"  ✓ cracked

with unique salt per user:
  hash("hunter2" + "a8f3c2e1...") = Y
  hash("hunter2" + "9b2d7f0a...") = Z   (different user, same password, different output)
  →  Y and Z are not in any table.  Attacker must crack each entry independently.
```

argon2id and bcrypt embed the salt in their output string — you don't manage salts manually. The `$argon2id$v=19$m=65536,t=3,p=4$<salt>$<hash>` string contains everything needed to verify.

### Pepper

A pepper is a server-side secret mixed into the hash before storage. Unlike a salt, it does not live in the database — it lives in a secret manager (Vault, GCP Secret Manager, AWS Secrets Manager).

```
hash( password + pepper )  → stored in DB
```

If an attacker gets the DB dump, they can't crack the hashes without the pepper. If they get the pepper, they still need to crack argon2id. Defense in depth.

```python
# Python: argon2-cffi
from argon2 import PasswordHasher
import os, hmac, hashlib

PEPPER = os.environ["PW_PEPPER"]   # 32 random bytes, hex-encoded; from secret manager

ph = PasswordHasher(
    time_cost=3,       # iterations (t)
    memory_cost=65536, # 64 MB (m)
    parallelism=4,     # lanes (p)
    hash_len=32,
    salt_len=16,
)

def hash_password(raw: str) -> str:
    peppered = hmac.new(PEPPER.encode(), raw.encode(), hashlib.sha256).hexdigest()
    return ph.hash(peppered)

def verify_password(stored: str, raw: str) -> bool:
    peppered = hmac.new(PEPPER.encode(), raw.encode(), hashlib.sha256).hexdigest()
    return ph.verify(stored, peppered)
```

### Tuning argon2id for your hardware

The OWASP recommendation as a floor: `m=64MB, t=3, p=4` (< 1 second on commodity hardware). Target ~300 ms for a login endpoint on your server. Under load this means argon2id is a natural rate-limiter for brute force — it's expensive on the attacker, not just on you.

```python
import time
from argon2 import PasswordHasher

ph = PasswordHasher(time_cost=3, memory_cost=65536, parallelism=4)
start = time.perf_counter()
ph.hash("benchmark")
elapsed = (time.perf_counter() - start) * 1000
print(f"{elapsed:.1f} ms")  # aim for 100–500 ms
```

If < 100 ms, raise `time_cost`. If > 500 ms, lower `memory_cost`. Never lower below `m=19456` (OWASP minimum).

---

## Credential Stuffing & Rate Limiting

Credential stuffing is not brute force. The attacker already has valid credentials — from a previous breach at another site — and is testing them against your login endpoint.

```
1.4 billion credentials from past breaches (freely available on the dark web)
→ replay against your login endpoint
→ 0.1–2% success rate on average (password reuse is epidemic)
→ 1 million attempts × 2% = 20,000 accounts compromised
```

### Defense layers

```
Layer 1: Rate limit by IP         — blocks naive scripts; circumvented by botnets
Layer 2: Rate limit by username   — blocks distributed attacks on one account
Layer 3: CAPTCHA after N failures — raises cost significantly
Layer 4: Leaked-password check    — reject known-breached passwords at signup
         (HaveIBeenPwned k-anonymity API: first 5 chars of SHA1, never the full hash)
Layer 5: Anomaly detection        — login from new country, new device fingerprint
Layer 6: MFA                      — credentials alone are not enough
```

Implement layers 1–4 even if you implement nothing else. Layer 5 is product-specific. Layer 6 is in Module 04.

```python
# Redis-backed rate limiter (sliding window, per-username)
import redis, time

r = redis.Redis()

def check_rate_limit(username: str, max_attempts: int = 5, window_s: int = 300) -> bool:
    key = f"login:fail:{username}"
    now = int(time.time() * 1000)
    window_start = now - window_s * 1000

    pipe = r.pipeline()
    pipe.zremrangebyscore(key, 0, window_start)
    pipe.zadd(key, {str(now): now})
    pipe.zcard(key)
    pipe.expire(key, window_s)
    _, _, count, _ = pipe.execute()

    return count > max_attempts   # True = block the request
```

A timing-safe comparison is mandatory for password-equivalent tokens. Python's `hmac.compare_digest` prevents timing attacks that let an attacker guess tokens byte by byte:

```python
import hmac
# NEVER: stored_token == submitted_token   (short-circuits on first mismatch)
# ALWAYS:
hmac.compare_digest(stored_token, submitted_token)
```

---

## Server Sessions

A session is a server-side record that maps an opaque identifier (the session ID) to a user's identity and state.

```
┌────────────┐   POST /login          ┌──────────────┐   create session
│  Browser   │ ──────────────────────► │  App Server  │ ─────────────────►  Redis
│            │   Set-Cookie: sid=X ◄── │              │   {X: {user_id: 99, roles: [...]}}
│            │                         │              │
│            │   GET /dashboard        │              │
│            │   Cookie: sid=X ───────►│              │   lookup X → principal
└────────────┘                         └──────────────┘
```

### What belongs in the session

Store the minimum. The session ID is opaque — its value is meaningless. The session store holds:

```json
{
  "user_id": "u_99",
  "roles": ["customer"],
  "created_at": 1735680000,
  "last_seen": 1735683600,
  "ip_fingerprint": "2001:db8::1",
  "2fa_verified": true
}
```

Do not store sensitive data or large objects in the session. Do not store the user's password, credit card, or anything you wouldn't want in a Redis key.

### Generating a session ID

A session ID must be cryptographically random and unguessable. Use `secrets.token_urlsafe(32)` in Python (32 bytes = 256 bits of entropy). Never use sequential integers, UUIDs derived from time, or any scheme an attacker can predict.

```python
import secrets
session_id = secrets.token_urlsafe(32)   # e.g. "ZXuaFq3-k7D_VN_eBE2GplHSrYmX7tJn8lQ9ZR0p4s"
```

---

## Secure Cookies

Cookies are the canonical transport for session IDs in a browser context. Three attributes are non-negotiable.

```
Set-Cookie: sid=ZXuaFq...; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=3600
```

| Attribute | What it does | Without it |
|-----------|-------------|-----------|
| `HttpOnly` | JavaScript cannot read this cookie (`document.cookie`) | XSS payload exfiltrates the session ID |
| `Secure` | Browser sends cookie only over HTTPS | Cookie transmitted in plaintext over HTTP |
| `SameSite=Lax` | Cookie not sent on cross-site POST/PUT/PATCH | CSRF attacks (cross-site form submissions) work |
| `SameSite=Strict` | Cookie not sent on any cross-site request (including navigation) | No cross-site session at all — some OAuth flows need Lax |

**`SameSite=Lax` is now the browser default** in Chrome/Firefox as of 2020. Do not rely on that — always set it explicitly. Set `Strict` if your app never needs to send cookies on cross-site navigation.

### `__Host-` prefix

The `__Host-` prefix forces the browser to enforce `Secure`, `Path=/`, and no `Domain` attribute:

```
Set-Cookie: __Host-sid=ZXuaFq...; HttpOnly; Secure; SameSite=Lax; Path=/
```

This prevents a subdomain from setting a cookie that leaks to the apex domain. Use it for any production session cookie.

---

## CSRF & Its Defenses

Cross-Site Request Forgery exploits the browser's automatic cookie inclusion: if you're logged into `bank.example`, and you visit `evil.example`, a hidden form on `evil.example` can POST to `bank.example/transfer` with your session cookie attached.

```
Attacker's page:
<form action="https://bank.example/transfer" method="POST">
  <input name="amount" value="9999">
  <input name="to" value="attacker_account">
</form>
<script>document.forms[0].submit()</script>
```

The bank's server sees a valid session cookie and processes the transfer.

### Defense 1 — SameSite=Lax (modern, primary)

`SameSite=Lax` stops the form POST above because it's a cross-site navigation initiated by `evil.example`, not by the user clicking a link to `bank.example`. This is sufficient for most apps in 2025.

### Defense 2 — Synchronizer Token Pattern (CSRF token)

For APIs or apps that need to support old browsers and non-SameSite flows:

```python
# On every HTML form render, embed a CSRF token
# The token is bound to the session and validated on POST
import secrets, hmac, hashlib

def generate_csrf_token(session_id: str, secret: str) -> str:
    return hmac.new(
        secret.encode(),
        session_id.encode(),
        hashlib.sha256
    ).hexdigest()

def validate_csrf_token(session_id: str, token: str, secret: str) -> bool:
    expected = generate_csrf_token(session_id, secret)
    return hmac.compare_digest(expected, token)
```

The token travels in the form body (not a cookie), so `evil.example` can't read it (SOP) and can't forge it (doesn't know the secret).

### Defense 3 — `Origin` / `Referer` header check

For SPAs that can't embed a CSRF token in every request:

```python
ALLOWED_ORIGINS = {"https://app.example.com", "https://www.example.com"}

def csrf_origin_check(request) -> bool:
    origin = request.headers.get("Origin") or request.headers.get("Referer", "")
    return any(origin.startswith(o) for o in ALLOWED_ORIGINS)
```

This fails silently for requests with no `Origin` (server-to-server, old IE). Use as a second layer, not the only layer.

---

## Session Fixation & Rotation

Session fixation: the attacker sets a known session ID *before* the user logs in. The user then logs in, and the attacker's known ID is now associated with the authenticated session.

```
1. Attacker visits /login → server creates unauthenticated session (sid=KNOWN)
2. Attacker tricks user into clicking: https://app.example/login?sid=KNOWN
   (old apps wrote the session ID into the URL or read it from a GET param)
3. User logs in; server upgrades the existing session KNOWN → authenticated
4. Attacker uses KNOWN — now authenticated as the victim
```

**Fix: rotate the session ID on every privilege escalation.**

```python
# After successful login — ALWAYS rotate
def on_login_success(session_store, old_sid: str, user_id: str) -> str:
    # 1. Copy any pre-auth state you want to keep
    old_data = session_store.get(old_sid) or {}

    # 2. Delete the old session
    session_store.delete(old_sid)

    # 3. Create a new session with a new ID
    new_sid = secrets.token_urlsafe(32)
    session_store.set(new_sid, {**old_data, "user_id": user_id, "authenticated": True})

    return new_sid   # set this in the response cookie
```

Rotate on: login, privilege escalation (e.g. sudo confirmation), password change, MFA verification. An unmutated session ID from the pre-auth state into the authenticated state is a fixation vulnerability.

---

## Debugging Passwords & Sessions

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| Passwords from a leaked DB cracked in hours | MD5 or SHA1 used; no salt; or bcrypt with cost=4 | Migrate to argon2id; force password reset for affected accounts |
| Rate-limiter bypassed; account locked for innocent user | Rate-limit keys only on IP (shared NAT) | Key on username; use exponential backoff, not hard lock |
| CSRF attack works despite `SameSite=Lax` | Cookie set without explicit `SameSite` (relying on browser default which may differ); or old browser | Set `SameSite` explicitly in every `Set-Cookie` |
| User logs in but still has the pre-login session ID | Session not rotated on login | Call `on_login_success` which deletes old ID and sets a new one |
| Session persists after logout | `session_store.delete(sid)` not called; or cookie deleted client-side but server-side record retained | Delete from server store on logout; set cookie expiry to past |
| Timing attack on login endpoint | `==` used to compare tokens | Replace with `hmac.compare_digest` |
| Session cookie readable by JavaScript | `HttpOnly` flag missing | Add `HttpOnly` to `Set-Cookie` |

### War story: the ghost session

> **War story.** At SAP, a colleague noticed that our staging CI environment showed logged-in state even after the session backend (Redis) was flushed between test runs. The root cause: a frontend SPA was reading the user object from `localStorage` after the session cookie was deleted. The `localStorage` item had been set at login time as a cache for the profile API response. Deleting the cookie logged out the backend, but the SPA's `isAuthenticated` guard checked `localStorage` first — and found a stale "user" object. The UX looked authenticated. The backend would 401 on any real API call, but the route guards never made a real API call on navigation. Three things fixed it: 1) clear `localStorage` on logout explicitly; 2) always validate the session server-side on app load, not just from client-side state; 3) treat any 401 from the API as an unconditional logout event regardless of local state.

Debugging the exact timing of a session rotation issue:

```bash
# In a browser: open DevTools → Network → filter "login"
# Look at the Set-Cookie response header after POST /login
# Confirm: new sid differs from the sid sent in Cookie: on the POST
curl -c old.jar -b old.jar -X POST https://app/login \
  -d "username=test&password=test" -D -
# -D - prints response headers; verify Set-Cookie has a new value
```

---

## Checkpoint

You're ready to move forward when you can answer these without looking:

1. Explain why SHA-256 is not a password hash. Name two properties argon2id has that SHA-256 lacks.
2. Write from memory the three `Set-Cookie` attributes that are non-negotiable for a session cookie. What happens if each is missing?
3. Describe credential stuffing in one sentence. Name two defenses that work against distributed (botnet) credential stuffing.
4. Explain session fixation. What one operation prevents it? When must that operation happen?
5. A user reports they are still logged in five minutes after clicking "logout." List three server-side causes and the fix for each.
6. Your CSRF tokens are bound to sessions and embedded in form bodies. An attacker's page does `fetch("https://app/transfer", {method:"POST", credentials:"include"})`. Does the CSRF token help? Why or why not?

➡ Next: **JWT, OAuth2 & OIDC** — the token formats that power every third-party login and service-to-service call, and the five ways developers get them catastrophically wrong.
