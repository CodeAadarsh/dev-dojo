# JWT OAuth2 — Bearer or 401

The team's new microservice merged without the auth middleware reviewed. It has `POST /token` stubbed, and the `/me` route returns the hardcoded user dict regardless of whether the request carries a token — or anything at all. A security pen-tester just filed ticket SEC-419: *"Every endpoint is publicly accessible. curl https://prod/me returns real user data with zero credentials."*

Your job: implement OAuth2 password flow with JWT so the verifier's scenarios pass.

## Context

`setup.sh` plants a project in your work directory:

```
~/.kube-dojo-work/04-jwt-oauth2/
├── main.py          # FastAPI app — skeleton with stubs; models and routes registered
└── tests/
    └── test_sample.py   # visible sample test (a smoke check you can run locally)
```

## Prerequisites

```bash
cd ~/.kube-dojo-work/04-jwt-oauth2
python3 -m venv .venv && . .venv/bin/activate
pip install fastapi "uvicorn[standard]" httpx pytest pydantic pyjwt
```

## Mission

Implement these exact behaviours in `main.py`:

| Scenario | Expected |
|----------|----------|
| `GET /me` with no `Authorization` header | **401** Unauthorized |
| `GET /me` with a valid `Bearer <token>` from `POST /token` | **200** OK, body contains `username` |
| `POST /token` with correct credentials (`username=alice`, `password=secret`) | **200**, body has `access_token` and `token_type: "bearer"` |
| `POST /token` with wrong password | **401** |
| `GET /me` with a tampered token (any bit flipped) | **401** |
| `GET /me` with a token signed with the wrong secret | **401** |

The verifier's hidden suite covers all six scenarios. Your skeleton already imports `jwt` (`PyJWT`) and has the secret constant and the user DB dict — you only need to fill in the logic.

### OAuth2 password flow, briefly

```
client --POST /token {username, password}--> server
server validates creds, signs JWT, returns {access_token, token_type}
client --GET /me Authorization: Bearer <token>--> server
server decodes + validates JWT, returns protected data
```

FastAPI ships `OAuth2PasswordBearer` and `OAuth2PasswordRequestForm` in `fastapi.security` — they wire the OpenAPI "Authorize" button automatically and handle extraction from the `Authorization` header.

### JWT anatomy

A JWT is three base64url-encoded JSON objects joined by dots: `header.payload.signature`. The signature is `HMAC-SHA256(base64url(header) + "." + base64url(payload), secret)`. Flipping any byte in header or payload invalidates the signature; using a different secret produces an entirely different signature. PyJWT's `jwt.decode(token, secret, algorithms=["HS256"])` raises `jwt.InvalidTokenError` on any of these — catch it and raise a 401.

### The `exp` claim

Always set `exp` in the payload. `jwt.decode` checks it automatically and raises `jwt.ExpiredSignatureError` (a subclass of `InvalidTokenError`) when the token is past its expiry. The skeleton sets a 30-minute expiry — keep it.

## Why this matters

Forgetting Bearer auth is the #1 auth bug in internal microservices. The service works in dev (no auth), it "works" in staging (smoke test hits only the happy path), and it reaches prod where the pen-tester files SEC-419. The fix is structural: `Depends(get_current_user)` in FastAPI makes the auth a compile-time contract, not a runtime afterthought.

## Verify

```bash
bash courses/course-15-fastapi-production/challenges/04-jwt-oauth2/verify.sh
```

All six hidden scenarios green → flag printed.
