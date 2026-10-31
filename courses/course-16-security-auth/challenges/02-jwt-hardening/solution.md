# Solution — JWT Hardening

## Complete `jwt_auth.py`

```python
import time
import jwt

SECRET_KEY = "dev-secret-do-not-use-in-production"
ALGORITHM = "HS256"
ISSUER = "kube-dojo"
AUDIENCE = "kube-dojo-api"


def issue_jwt(subject: str) -> str:
    now = int(time.time())
    payload = {
        "sub": subject,
        "iss": ISSUER,
        "aud": AUDIENCE,
        "iat": now,
        "exp": now + 900,
    }
    return jwt.encode(payload, SECRET_KEY, algorithm=ALGORITHM)


def verify_jwt(token: str) -> dict:
    return jwt.decode(
        token,
        SECRET_KEY,
        algorithms=[ALGORITHM],
        audience=AUDIENCE,
        issuer=ISSUER,
        options={"require": ["exp", "iat", "iss", "aud", "sub"]},
    )
```

## Why each piece prevents the attack

**`algorithms=["HS256"]` — the essential fix.**
`jwt.decode()` accepts a list of algorithms it is willing to honour. When you pass `["HS256"]`, PyJWT rejects any token whose header declares a different algorithm — including `"none"`, `"NONE"`, and `"None"`. The library does not even look at the signature segment if the algorithm doesn't match. This one parameter closes the alg:none bypass entirely.

**`audience=AUDIENCE` + `issuer=ISSUER`.**
PyJWT validates `aud` and `iss` claims when you pass them to `decode()`. A token issued by another service (wrong `aud`) or forged with the wrong `iss` is rejected with `InvalidAudienceError` or `InvalidIssuerError`, both subclasses of `InvalidTokenError`. Without these, a token stolen from another service in the same org would be accepted.

**`exp` is checked automatically** when it is present. But without `options={"require": [...]}`, a token with no `exp` claim at all would pass — infinite lifetime. The `require` list forces the claim to exist.

**Never pass `options={"verify_signature": False}`.**
That disables the entire signature check. It has legitimate uses (token inspection without the secret) but never in a path that grants access. Grep your codebase for it periodically.

## Attacker's view: forging a token manually

```python
import base64, json, time

def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()

header = b64url(json.dumps({"alg": "none", "typ": "JWT"}).encode())
payload = b64url(json.dumps({
    "sub": "admin",
    "iss": "kube-dojo",
    "aud": "kube-dojo-api",
    "iat": int(time.time()),
    "exp": int(time.time()) + 9999999,
}).encode())

forged = f"{header}.{payload}."  # trailing dot = empty signature
```

The `forged` token would be accepted by any `jwt.decode()` call that does not pass `algorithms=["HS256"]`. Your fixed implementation rejects it at the algorithm check before touching the signature.

## Verify

```bash
cd ~/.kube-dojo-work/02-jwt-hardening
bash courses/course-16-security-auth/challenges/02-jwt-hardening/verify.sh
```
