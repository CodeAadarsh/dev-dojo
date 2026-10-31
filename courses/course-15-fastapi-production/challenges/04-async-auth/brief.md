# Async Auth Endpoints

You've just joined the team that owns the internal developer portal. The auth module was
stubbed in a spike two weeks ago with `raise HTTPException(status_code=501)` placeholders and
never finished. A ticket in the backlog reads: *"Auth is completely broken. Register, login, and
/users/me all return 501. Unblocking every other team."* Priority: P0.

## Context

`setup.sh` plants a skeleton in your work directory:

```
~/.kube-dojo-work/04-async-auth/
├── main.py           # FastAPI app — User model, endpoint stubs, and all the pieces
└── tests/
    └── test_sample.py  # one visible test to confirm your basic setup works
```

The skeleton includes `User` schema, `pwd_context`, `oauth2_scheme`, and `SECRET_KEY`. Only the
three endpoint bodies are stubs. The auth infrastructure is yours to wire together.

## Prerequisites

```bash
cd ~/.kube-dojo-work/04-async-auth
python3 -m venv .venv && . .venv/bin/activate
pip install fastapi "uvicorn[standard]" httpx pytest pydantic pyjwt "passlib[bcrypt]"
```

## Mission

Implement the three endpoint bodies in `main.py`:

| Endpoint | Method | Expected behaviour |
|----------|--------|-------------------|
| `POST /auth/register` | Register a new user | **201** Created with `{username, email}`; **409** if username already exists |
| `POST /auth/token` | OAuth2 password flow | **200** with `{access_token, token_type: "bearer"}`; **401** on wrong password or unknown user |
| `GET /users/me` | Return the current authenticated user | **200** with `{username, email}`; **401** if token missing, expired, or tampered |

Rules the verifier enforces:
- Passwords must be stored **hashed** — plaintext in `_users_db` will not satisfy the password
  verification check.
- The JWT `sub` claim must be the username string, not a user object.
- `jwt.ExpiredSignatureError` and `jwt.InvalidTokenError` must both be caught and mapped to 401.
- A token with the signature bytes modified must return 401, not 500.

## Why it matters

The register/login/me triad is the lowest common denominator of every protected API. Getting the
HTTP semantics exactly right (201 vs 200, 401 with `WWW-Authenticate: Bearer`) is what makes
clients behave correctly without special-casing. Getting the security details right (bcrypt, HS256
only, `exp` in UTC) is what makes the system not appear in a OWASP Top 10 postmortem.

## Verify

```bash
bash courses/course-15-fastapi-production/challenges/04-async-auth/verify.sh
```

All tests green → flag printed.
