# JWT Login and Protected Routes

The auth spec is two lines: *"/login issues a token; /protected returns 401 without it."* Sounds simple. The trap is in verification: many first implementations decode the JWT to check the signature but forget to handle the case where the token was signed by a different key — or no key at all. The verifier deliberately forges a token with the wrong secret to catch exactly this.

JSON Web Tokens are **signed, not encrypted**. The payload is base64-encoded and readable by anyone. What the signature guarantees is integrity: only a server with the correct secret could have produced it. If your `/protected` handler decodes the payload without verifying the signature, an attacker can craft any claims they want.

## Working directory

`setup.sh` plants a skeleton in:

```
~/.kube-dojo-work/03-jwt-auth/
  app.py             ← implement /login and /protected here
  tests/
    test_harness.py  ← DO NOT EDIT (run by verify.sh)
```

## Prerequisites

```bash
cd ~/.kube-dojo-work/03-jwt-auth
python3 -m venv .venv && . .venv/bin/activate
pip install flask pytest pyjwt
```

## Mission

Edit `app.py`. The skeleton has one hardcoded user: `admin` / `secret`.

**`POST /login`** — accepts `{"username": "...", "password": "..."}`:
- Wrong credentials → `401`
- Valid credentials → `200` with `{"token": "<jwt>"}`

The JWT must be signed with `app.config['SECRET_KEY']` using HS256. Include at minimum a `sub` claim (the username) and an `exp` claim (expiry, e.g. 1 hour from now).

**`GET /protected`** — reads `Authorization: Bearer <token>` header:
- Missing header → `401`
- Token present but invalid (bad signature, expired, malformed) → `401`
- Valid token → `200` with any JSON body

The verifier mints a token with a **wrong secret key** and confirms your handler rejects it. A handler that skips signature verification will fail this test.

## The security angle

`jwt.decode(token, key, algorithms=['HS256'])` raises `jwt.PyJWTError` (or a subclass) on any verification failure. Catch the base class so you handle expired tokens, bad signatures, and malformed payloads with a single `except`. Never catch `Exception` — it masks real bugs in your route logic.

`algorithms=` is a required list, not a string. PyJWT enforces this to prevent algorithm-confusion attacks: an attacker can craft a token that says `"alg": "none"` in the header; if the library accepts it, the "signature" is empty and the token validates against anything. Passing an explicit allowlist closes that door.

## Verify

```bash
bash courses/course-12-flask-production/challenges/03-jwt-auth/verify.sh
```

All six harness tests green → flag printed.
