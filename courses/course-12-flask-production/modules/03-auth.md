# Authentication: Sessions & JWT

> **Module 03 · Course 12** — Authentication is the part of the codebase where mistakes cost the most and are discovered the latest. The failure modes are not "wrong output" — they're "silent access to data that should have been off limits." Know what you're choosing when you pick server sessions vs tokens, and know the attacks that target each.

---

## Password Hashing

Never store plaintext passwords, reversible encodings, or fast hashes (MD5, SHA-1, SHA-256). Fast hash functions are designed to be fast — that's the problem. An attacker with your database can try billions of MD5 candidates per second on commodity hardware.

Use an adaptive, slow, salted hash: **bcrypt** or **argon2**.

### bcrypt

```python
# app/models/user.py
from flask_bcrypt import Bcrypt

bcrypt = Bcrypt()   # init_app(app) in create_app()

class User(db.Model):
    ...
    password_hash: db.Mapped[str] = db.mapped_column(db.String(128), nullable=False)

    def set_password(self, plaintext: str) -> None:
        self.password_hash = bcrypt.generate_password_hash(plaintext, rounds=12).decode("utf-8")

    def check_password(self, plaintext: str) -> bool:
        return bcrypt.check_password_hash(self.password_hash, plaintext)
```

`rounds=12` means 2^12 iterations. Each increment roughly doubles cost. At 12, hashing takes ~250ms on modern hardware — slow enough to make brute-force expensive, fast enough that a login endpoint doesn't feel broken. Bump to 13 when your hardware doubles; never go below 10.

### argon2 (prefer for new projects)

argon2 won the 2015 Password Hashing Competition. It's memory-hard: an attacker can't parallelize it cheaply on GPU clusters because each hash requires a configurable chunk of RAM.

```python
from argon2 import PasswordHasher
from argon2.exceptions import VerifyMismatchError

ph = PasswordHasher(time_cost=2, memory_cost=65536, parallelism=2)   # 64 MB per hash

class User(db.Model):
    ...
    def set_password(self, plaintext: str) -> None:
        self.password_hash = ph.hash(plaintext)

    def check_password(self, plaintext: str) -> bool:
        try:
            return ph.verify(self.password_hash, plaintext)
        except VerifyMismatchError:
            return False
```

Never compare hash strings with `==`. Always use the library's `verify()`. A constant-time comparison inside the library protects against timing attacks; string equality does not.

### Timing attack protection on the login endpoint

Even with a proper hash, a login endpoint that returns instantly for unknown emails and slowly for wrong passwords leaks whether an account exists. Defend with a constant-time dummy hash:

```python
_DUMMY_HASH = ph.hash("dummy-prevents-timing-attack")

@auth_bp.post("/login")
def login():
    data = request.get_json(force=True)
    user = db.session.execute(
        db.select(User).where(User.email == data.get("email", ""))
    ).scalar_one_or_none()

    if user is None:
        # Hash anyway so the response time is the same whether the user exists or not
        ph.verify(_DUMMY_HASH, data.get("password", ""))
        return jsonify({"error": "invalid credentials"}), 401

    if not user.check_password(data.get("password", "")):
        return jsonify({"error": "invalid credentials"}), 401

    return jsonify({"token": issue_access_token(user)}), 200
```

---

## Server Sessions vs Stateless JWT

Two fundamentally different tradeoffs. Neither is universally correct.

| Property | Server session (Flask default) | JWT (stateless token) |
|----------|-------------------------------|-----------------------|
| **State location** | Server (DB / Redis) — client holds an opaque ID | Client only — server holds no state |
| **Revocation** | Instant: delete the session row | Hard by default: token is valid until expiry (need a denylist to revoke) |
| **Scalability** | Session store must be shared across instances (sticky sessions or Redis) | Trivially horizontal — any instance can verify a signature |
| **Payload visibility** | Opaque to client | Decodeable by anyone (not encrypted by default — just signed) |
| **CSRF exposure** | Yes — cookies are sent automatically by browsers | No — `Authorization` header isn't sent automatically |
| **Token theft** | Cookie can be `HttpOnly` — JS can't steal it | Bearer token in `localStorage` is vulnerable to XSS |

**Rule of thumb:** use server sessions for traditional web apps with login forms and a single domain. Use JWTs for APIs consumed by mobile clients, SPAs on different domains, or microservices where you don't want a central session store.

---

## Flask-Login (Server Sessions)

Flask-Login manages the "logged in / logged out" state via a session cookie. It integrates with Flask's signed cookie session — the session ID is a cryptographically signed value using `SECRET_KEY`, not a raw UUID.

```python
# app/extensions.py
from flask_login import LoginManager
login_manager = LoginManager()
login_manager.login_view = "auth.login"   # redirect to this endpoint if not logged in
```

```python
# app/models/user.py
from flask_login import UserMixin

class User(UserMixin, db.Model):
    # UserMixin provides: is_authenticated, is_active, is_anonymous, get_id()
    ...
```

```python
# app/__init__.py — in create_app()
@login_manager.user_loader
def load_user(user_id: str):
    return db.session.get(User, int(user_id))
```

```python
# app/api/auth/routes.py
from flask_login import login_user, logout_user, login_required, current_user

@auth_bp.post("/login")
def login():
    data = request.get_json(force=True)
    user = authenticate(data["email"], data["password"])   # your verify function
    if user is None:
        return jsonify({"error": "invalid credentials"}), 401
    login_user(user, remember=data.get("remember", False))
    return jsonify({"id": user.id}), 200


@auth_bp.post("/logout")
@login_required
def logout():
    logout_user()
    return "", 204


@users_bp.get("/me")
@login_required
def me():
    return jsonify({"id": current_user.id, "email": current_user.email}), 200
```

`login_user()` writes the user's ID into the Flask session (the signed cookie). `load_user` is called on every request to reload the full `User` object. One DB query per request — that's the cost of server-side identity.

---

## Stateless JWT

```python
# app/auth/tokens.py
import time
import hmac
import hashlib
import base64
import json
import os
from flask import current_app
from app.models import User


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def issue_access_token(user: User) -> str:
    header = {"alg": "HS256", "typ": "JWT"}
    now = int(time.time())
    payload = {
        "sub": str(user.id),
        "email": user.email,
        "roles": user.roles,          # list of strings
        "iat": now,
        "exp": now + current_app.config["JWT_ACCESS_TTL_SECONDS"],
    }
    signing_input = (
        _b64url(json.dumps(header).encode()) + "." + _b64url(json.dumps(payload).encode())
    )
    secret = current_app.config["SECRET_KEY"].encode()
    sig = hmac.new(secret, signing_input.encode(), hashlib.sha256).digest()
    return signing_input + "." + _b64url(sig)
```

In practice use [PyJWT](https://pyjwt.readthedocs.io/):

```python
import jwt as pyjwt
from datetime import datetime, timezone, timedelta


def issue_access_token(user: User) -> str:
    now = datetime.now(timezone.utc)
    payload = {
        "sub": str(user.id),
        "email": user.email,
        "roles": user.roles,
        "iat": now,
        "exp": now + timedelta(seconds=current_app.config["JWT_ACCESS_TTL_SECONDS"]),
    }
    return pyjwt.encode(
        payload,
        current_app.config["SECRET_KEY"],
        algorithm="HS256"
    )


def decode_access_token(token: str) -> dict:
    return pyjwt.decode(
        token,
        current_app.config["SECRET_KEY"],
        algorithms=["HS256"],      # explicit allowlist — never omit this
        options={"require": ["sub", "exp", "iat"]},
    )
```

Wire it into `before_request` via `g`:

```python
@app.before_request
def authenticate_request():
    header = request.headers.get("Authorization", "")
    if not header.startswith("Bearer "):
        g.current_user = None
        return
    token = header.removeprefix("Bearer ")
    try:
        g.current_user = decode_access_token(token)
    except pyjwt.ExpiredSignatureError:
        return jsonify({"error": "token expired"}), 401
    except pyjwt.InvalidTokenError:
        return jsonify({"error": "invalid token"}), 401
```

### Token Refresh

Short-lived access tokens (15 min) + long-lived refresh tokens (7–30 days). The refresh token is used only once, at a dedicated endpoint, to issue a new access token.

```python
# app/models/refresh_token.py
import secrets
from datetime import datetime, timezone, timedelta
from app.extensions import db


class RefreshToken(db.Model):
    __tablename__ = "refresh_tokens"

    id: db.Mapped[int] = db.mapped_column(primary_key=True)
    token_hash: db.Mapped[str] = db.mapped_column(db.String(64), unique=True, nullable=False, index=True)
    user_id: db.Mapped[int] = db.mapped_column(db.ForeignKey("users.id"), nullable=False)
    expires_at: db.Mapped[datetime] = db.mapped_column(nullable=False)
    revoked: db.Mapped[bool] = db.mapped_column(default=False)

    user: db.Mapped["User"] = db.relationship("User")

    @classmethod
    def create(cls, user_id: int, ttl_days: int = 30) -> tuple["RefreshToken", str]:
        raw = secrets.token_urlsafe(32)
        token_hash = hashlib.sha256(raw.encode()).hexdigest()
        rt = cls(
            token_hash=token_hash,
            user_id=user_id,
            expires_at=datetime.now(timezone.utc) + timedelta(days=ttl_days),
        )
        db.session.add(rt)
        return rt, raw   # return raw once; store only the hash


@auth_bp.post("/refresh")
def refresh():
    raw_token = request.get_json(force=True).get("refresh_token", "")
    token_hash = hashlib.sha256(raw_token.encode()).hexdigest()
    rt = db.session.execute(
        db.select(RefreshToken).where(
            RefreshToken.token_hash == token_hash,
            RefreshToken.revoked == False,
            RefreshToken.expires_at > datetime.now(timezone.utc),
        )
    ).scalar_one_or_none()
    if rt is None:
        return jsonify({"error": "invalid or expired refresh token"}), 401
    # Rotate: revoke the old, issue a new one
    rt.revoked = True
    new_rt, raw = RefreshToken.create(rt.user_id)
    db.session.commit()
    return jsonify({
        "access_token": issue_access_token(rt.user),
        "refresh_token": raw,
    }), 200
```

Store only the hash of the refresh token — if your database leaks, raw tokens are useless to an attacker.

---

## CSRF

CSRF is only relevant for **cookie-based auth** — `Authorization: Bearer` is not sent automatically by browsers, so JWT APIs are not CSRF-vulnerable. For Flask-Login + session cookies, you need CSRF protection on every state-changing endpoint.

```python
# app/extensions.py
from flask_wtf.csrf import CSRFProtect
csrf = CSRFProtect()   # init_app(app) in create_app()
```

Flask-WTF generates a token tied to the session and validates it on POST/PUT/PATCH/DELETE. For an AJAX-heavy or SPA frontend, read the token from the cookie and send it as a header:

```python
# Single-page app: Flask-WTF checks X-CSRFToken header automatically
# In your JS:
# const csrfToken = document.cookie.match(/csrf_token=([^;]+)/)?.[1];
# fetch("/api/data", { method: "POST", headers: { "X-CSRFToken": csrfToken }, ... })
```

Disable only in test config:

```python
class TestingConfig(Config):
    WTF_CSRF_ENABLED = False   # tests use the test client, no real browser session
```

---

## Scopes & Roles

A simple role-based access control system. Roles stored in the JWT `roles` claim (or in the DB for server sessions):

```python
# app/auth/decorators.py
from functools import wraps
from flask import g, jsonify


def require_roles(*roles: str):
    def decorator(f):
        @wraps(f)
        def wrapped(*args, **kwargs):
            if g.current_user is None:
                return jsonify({"error": "authentication required"}), 401
            user_roles = set(g.current_user.get("roles", []))
            if not user_roles.intersection(roles):
                return jsonify({"error": "insufficient permissions"}), 403
            return f(*args, **kwargs)
        return wrapped
    return decorator
```

```python
# Usage in a route
@users_bp.delete("/<int:user_id>")
@require_roles("admin")
def delete_user(user_id: int):
    ...
```

For anything more complex — resource-level permissions, attribute-based access — use [flask-principal](https://pythonhosted.org/Flask-Principal/) or implement a proper permission matrix. Simple string role lists in JWTs do not scale to fine-grained permission systems; move role data out of the token and into a fast cache (Redis) when you hit that wall.

---

## Debugging Authentication

| Symptom | Cause | Fix |
|---------|-------|-----|
| Session token is valid before login, invalid after (session fixation) | Session cookie isn't regenerated on privilege change — an attacker pre-sets a known session ID before the victim logs in, then inherits the authenticated session | Call `flask.session.clear()` and set a new session via `login_user()` on every login; Flask-Login's `login_user` handles this when `session.permanent` is managed correctly |
| JWT library accepts `{"alg": "none"}` header — signature is not checked | The `algorithms` allowlist was omitted from `pyjwt.decode()` — some versions default to accepting the `none` algorithm | Always pass `algorithms=["HS256"]` (or your actual algorithm) explicitly; never pass `algorithms=None` or an empty list |
| JWT `SECRET_KEY` visible in logs or error responses | `app.config["SECRET_KEY"]` logged in a debug traceback, or returned in a 500 response body | Set `PROPAGATE_EXCEPTIONS = True` and let Sentry/structlog capture it server-side; never return `str(e)` in a production response |
| `@login_required` redirects API clients to the login HTML page | `LoginManager.login_view` is set and Flask-Login sends a 302 for unauthorized API requests | Override `LoginManager.unauthorized_handler` to return a 401 JSON response for API routes; use `request.is_json` or an `Accept` header check to decide |
| Password reset tokens re-usable after first use | Token stored as plaintext and never invalidated after use | Store a hash; mark token `used=True` on first redemption; expire tokens with a short TTL (15 min) |
| `401` on refresh — token was correct yesterday | Refresh token rotated but old raw token was cached by client | Implement token rotation correctly: old hash invalidated atomically in the same commit that issues the new one; client must store the new token from the response |

### Exact commands

```bash
# Inspect a JWT without a library — three base64url segments
TOKEN="eyJhbGc..."
echo $TOKEN | cut -d. -f1 | base64 -d 2>/dev/null   # header
echo $TOKEN | cut -d. -f2 | base64 -d 2>/dev/null   # payload (add == padding if needed)

# Verify a JWT signature from the CLI (PyJWT installed)
python3 -c "
import jwt
print(jwt.decode('$TOKEN', 'your-secret-key', algorithms=['HS256']))
"

# Check for algorithm confusion — does the library accept 'none'?
python3 -c "
import jwt
# If this succeeds, your decode() call is missing the algorithms allowlist
forged = jwt.encode({'sub': '1', 'exp': 9999999999}, '', algorithm='none')
print(jwt.decode(forged, '', algorithms=['none']))
"

# Test login endpoint timing (should be ~constant regardless of whether email exists)
for i in 1 2 3 4 5; do
    time curl -s -X POST http://localhost:5000/auth/login \
        -H "Content-Type: application/json" \
        -d '{"email":"notexist@example.com","password":"wrong"}' > /dev/null
done

# Verify Flask session cookie is HttpOnly + Secure + SameSite in production
curl -I http://localhost:5000/auth/login   # look for Set-Cookie: session=...; HttpOnly; Secure; SameSite=Lax
```

> **War story.** A colleague's service was issuing JWTs and specifying `algorithms=["HS256", "RS256"]` in `pyjwt.decode()` because they planned to support both. They never shipped RS256, but the allowlist stayed. Six months later a security audit found that an attacker who knew the API accepted HS256 could forge a token by using the RS256 *public key* as the HS256 *secret* — an algorithm confusion attack. The public key was, naturally, public. The fix is always the same: `algorithms` must contain exactly the algorithm(s) your token issuance code uses. If you're issuing HS256, accept only `["HS256"]`. If you rotate to RS256 later, remove HS256 from the allowlist immediately. An algorithm allowlist is not a "supported list"; it's the list of algorithms you vetted today.

---

## Checkpoint

You're ready to move on when you can, without looking anything up:

1. Explain why bcrypt and argon2 are appropriate for password hashing and MD5/SHA-256 are not.
2. Implement `set_password` and `check_password` on a `User` model using argon2.
3. Explain the constant-time dummy hash pattern and which attack it mitigates.
4. State three concrete tradeoffs between server sessions and JWTs and when you'd choose each.
5. Implement a `decode_access_token` function that explicitly specifies the `algorithms` allowlist and `require` fields.
6. Explain the JWT `none` algorithm attack and exactly how the `algorithms` parameter in PyJWT prevents it.
7. Implement a refresh token rotation: issue, store (hashed), verify, and rotate in one atomic commit.
8. Explain when CSRF protection is necessary and when it is not, relative to your auth mechanism.
9. Write a `require_roles` decorator that returns 401 for unauthenticated and 403 for unauthorized.

➡ Next: **REST API Design** — status codes, error envelopes, pagination, rate limiting, and versioning.
