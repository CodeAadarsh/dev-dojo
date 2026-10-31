# JWT Hardening

A penetration tester filed this against your auth service:

> **HIGH — CVE-style: Algorithm Confusion / alg:none bypass**
> The `verify_jwt` function accepts a token whose header says `"alg": "none"` and whose signature segment is empty. This is an unauthenticated forgery — an attacker crafts any payload they want, strips the signature, sets alg:none, and the service accepts it as valid.

The PR description adds: *"Also: no `exp`, no `aud`, no `iss`. Any stolen token is valid forever on any service."*

## Context

`setup.sh` plants a starter module and a visible sample test:

```
~/.kube-dojo-work/02-jwt-hardening/
├── jwt_auth.py      # issue_jwt / verify_jwt stubs
└── tests/
    └── test_sample.py
```

## Prerequisites

```bash
pip install pytest argon2-cffi pyjwt pyotp
```

`pyjwt` version **2.x** is required — the API changed significantly from 1.x.

## Mission

Implement two functions in `jwt_auth.py`:

### `issue_jwt(subject: str) -> str`

Issue an HS256-signed JWT with these claims:

| Claim | Value |
|-------|-------|
| `sub` | the `subject` argument |
| `iss` | `"kube-dojo"` |
| `aud` | `"kube-dojo-api"` |
| `iat` | `int(time.time())` |
| `exp` | `iat + 900` (15 minutes) |

### `verify_jwt(token: str) -> dict`

Verify the token and return the decoded payload. Must **raise** `jwt.exceptions.InvalidTokenError` (or any subclass) for:

| Attack | Example |
|--------|---------|
| `alg:none` | header `{"alg":"none"}`, signature omitted |
| `alg:NONE` / `alg:None` | same attack, mixed case |
| Wrong signature | valid structure, one char changed in signature |
| Expired token | `exp` is in the past |
| Wrong audience | token issued for `"evil-service"` not `"kube-dojo-api"` |

A valid token (correct sig, not expired, correct aud) must return the payload dict.

## The alg:none attack explained

JWT header + payload are just base64url-encoded JSON — not signed. The signature is the third segment. The algorithm header tells the library *how* to verify the signature. An attacker who knows your header format can:

1. Decode the original token header and payload (no secret needed — they're not encrypted).
2. Modify the payload (change `sub` to `admin`).
3. Re-encode with `"alg": "none"` and an empty signature segment.
4. Send `<modified_header>.<modified_payload>.` — the trailing dot signals "no signature."

If your library blindly honours the `alg` field from the incoming token (it knows which algorithm to use because the token says so), it accepts the forgery. The fix is to **pass `algorithms=["HS256"]` explicitly** to `jwt.decode()` — the library then rejects any token whose header specifies a different algorithm.

## Verify

```bash
bash courses/course-16-security-auth/challenges/02-jwt-hardening/verify.sh
```

All tests green → flag printed.
