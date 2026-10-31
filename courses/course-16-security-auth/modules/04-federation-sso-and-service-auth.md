# Federation, SSO & Service-to-Service Auth

> **Module 04 · Course 16** — Single sign-on exists to stop every application from being its own password database. Federation exists to stop every company from being its own IdP. And workload identity exists because service-to-service trust built on shared secrets is the brittle thing you quietly maintain until the day it isn't. This module is about all three layers: how they compose, where they break, and what a secure implementation actually looks like in production.

You already know that a user shouldn't have one password per app. The interesting question is how a 20,000-person enterprise routes that single login through three SaaS vendors, a private data center, and a Kubernetes cluster — and how a pod in that cluster proves who it is to an external API without ever storing a credential.

---

## SAML 2.0 & Enterprise SSO

SAML 2.0 is the protocol that underlies every "Log In with Corporate SSO" button in enterprise SaaS. Despite being XML-era technology (2005), it still dominates enterprise because Okta, Azure AD, and Ping Identity all speak it natively and IT departments have years of investment.

The three actors:

```
  User               Service Provider (SP)           Identity Provider (IdP)
  ──────             ─────────────────────           ─────────────────────
  browser            your app (the verifier)         Okta / Azure AD
                     (trusts the IdP)                (owns the user database)
```

The SP-initiated SSO flow — the dominant path:

```
1. User hits app.corp/dashboard (unauthenticated)
2. SP generates an AuthnRequest XML, signs it, and redirects the browser to:
   IdP SSO URL?SAMLRequest=<deflate+base64(AuthnRequest)>&RelayState=<return URL>
3. IdP authenticates the user (password, MFA, existing session)
4. IdP builds a SAML Assertion XML:
   - Issuer (who signed it)
   - Subject (NameID = user identity)
   - Conditions (NotBefore, NotOnOrAfter, AudienceRestriction)
   - AttributeStatement (email, groups, roles)
   - Signed with IdP private key
5. IdP POST-binds the Response to the SP's ACS URL:
   POST /saml/acs  Body: SAMLResponse=<base64(ResponseXML)>&RelayState=...
6. SP validates the signature, checks Conditions, extracts attributes, creates session
```

The fields that matter to an SDE integrating SAML:

| Field | What it is | What breaks if wrong |
|-------|-----------|----------------------|
| `ACS URL` | Where the IdP posts assertions | SP rejects the response (wrong destination) |
| `Entity ID` | Unique URI identifying the SP | IdP won't find the config; assertion misdirected |
| `Audience` | Must match the SP's Entity ID | SP rejects assertion (AudienceRestriction check) |
| `NameID format` | `emailAddress`, `persistent`, `transient` | User ID mapping fails; every login looks new |
| `NotBefore` / `NotOnOrAfter` | Assertion validity window, ±5 minutes | Clock-skew rejections (see Debugging section) |
| `AttributeStatement` | Groups, email, custom claims | RBAC in your app can't map roles → 403 after SSO |
| SP certificate | Your app's signing cert | IdP can't verify AuthnRequest; metadata mismatch |

Registering an SP with an enterprise IdP means exchanging metadata XML. Both sides publish a `metadata.xml` that contains the entity ID, ACS URL, and X.509 certificate. The most common integration error: the SP's metadata certificate expires and nobody notices until SSO breaks at 3 am.

> **SP-initiated vs IdP-initiated.** IdP-initiated flows (the IdP pushes an unsolicited assertion) lack the `InResponseTo` nonce check that SP-initiated flows have — meaning a valid assertion replayed from a previous session can log in a different user. Always require SP-initiated flows if you control the integration, and always validate `InResponseTo`.

### Signing vs Encryption in SAML

SAML has two orthogonal security operations that people conflate:

- **Signing** the assertion = the SP verifies the IdP signed it (integrity + authenticity). Required.
- **Encrypting** the assertion = the IdP wraps the assertion with the SP's public key so only the SP can read it. Recommended for sensitive attributes, not always enforced.

An assertion that is **signed but not encrypted** is integrity-protected but readable by anyone in the browser's network path (cookie stores, browser extensions, logging middleware). An assertion that is **encrypted but not signed** would let any attacker-controlled HTTPS endpoint decrypt it — so you always sign, and optionally also encrypt.

---

## OIDC Federation

OpenID Connect (OIDC) is OAuth 2.0 + an identity layer. Where OAuth only defines how to get a token authorizing access to a resource, OIDC adds the **ID token**: a signed JWT that says who the user is.

The key difference from SAML: everything is JSON over HTTPS, and tokens travel as compact JWTs rather than large XML envelopes.

```
┌─────────────┐     1. Authorization Code       ┌──────────────────┐
│  Client App │ ──────────────────────────────▶  │  Authorization   │
│  (RP)       │     2. code via redirect          │  Server (IdP/OP) │
│             │ ◀──────────────────────────────   │                  │
│             │     3. exchange code for tokens    │                  │
│             │ ──────────────────────────────▶   │  issues:         │
│             │     4. access_token + id_token     │  - id_token JWT  │
│             │ ◀──────────────────────────────   │  - access_token  │
│             │     5. fetch /userinfo if needed   │  - refresh_token │
│             │ ──────────────────────────────▶   └──────────────────┘
└─────────────┘
```

The ID token is a JWT. Its standard claims:

```json
{
  "iss": "https://accounts.google.com",
  "sub": "1098234567890",
  "aud": "your-client-id",
  "exp": 1700000000,
  "iat": 1699996400,
  "email": "aadarsh@corp.com",
  "email_verified": true,
  "nonce": "abc123"
}
```

Validation a Relying Party (RP, your app) must perform:

1. `iss` matches the expected IdP URL
2. `aud` contains the client's `client_id`
3. `exp` > now (not expired)
4. Signature verifies against the IdP's JWKS (`GET <issuer>/.well-known/openid-configuration` → `jwks_uri`)
5. `nonce` matches the value sent in the auth request (replay prevention)

Missing any one of these checks is a real CVE waiting to happen. The `nonce` check is the one most commonly skipped in homegrown OIDC implementations.

### OIDC for Kubernetes — the Kubernetes OIDC authenticator

Kubernetes natively speaks OIDC: configure `--oidc-issuer-url`, `--oidc-client-id`, and optionally `--oidc-username-claim`/`--oidc-groups-claim` on the API server, and users who present a valid OIDC ID token get authenticated by the API server directly.

```yaml
# kube-apiserver flags (kind: in /etc/kubernetes/manifests/kube-apiserver.yaml)
- --oidc-issuer-url=https://accounts.google.com
- --oidc-client-id=k8s-dojo-cluster
- --oidc-username-claim=email
- --oidc-groups-claim=groups
- --oidc-ca-file=/etc/kubernetes/oidc-ca.crt    # if IdP uses private CA
```

The practical implication: once configured, a user runs `kubectl` with a token generated by their OIDC IdP, and RBAC binds their `email` (or a group from the `groups` claim) to roles. No static kubeconfig certificate per human — just rotate via IdP session expiry.

```bash
# fetch an id_token and use it with kubectl
kubectl get pods --token="$(cat ~/.kube/oidc-token)"
# or configure it in kubeconfig under user.token/user.exec
```

---

## SCIM Provisioning

SAML and OIDC handle *authentication*. They do not handle *provisioning* — the act of creating, updating, or deactivating user accounts in a system when HR makes a change.

SCIM (System for Cross-domain Identity Management) is the REST API protocol for that. The IdP (Okta, Azure AD) acts as the SCIM client, pushing events to SCIM servers in downstream apps:

```
HR system                  Okta (IdP / SCIM client)         Your app (SCIM server)
──────────                 ────────────────────────         ─────────────────────
employee joins ──events──▶ Create user in Okta ──POST /Users──▶ Create local account
role changes  ──events──▶ Update user attrs   ──PATCH /Users/:id──▶ Update roles
employee leaves ─events──▶ Deactivate user    ──PATCH /Users/:id {active:false}──▶ Revoke access
```

SCIM endpoints follow a REST schema with a specific JSON structure:

```bash
# SCIM create user
POST /scim/v2/Users
Authorization: Bearer <service-token>
Content-Type: application/scim+json

{
  "schemas": ["urn:ietf:params:scim:schemas:core:2.0:User"],
  "userName": "aadarsh@corp.com",
  "name": {"givenName": "Aadarsh", "familyName": "Verma"},
  "emails": [{"value": "aadarsh@corp.com", "primary": true}],
  "active": true,
  "groups": [{"value": "grp-sde", "display": "SDE"}]
}
```

The critical security consideration: the service token authorizing SCIM write operations is highly privileged — it can create users and change group memberships. Rotate it like a DB root password, scope it to `POST /scim/v2/Users,Groups` only (not all endpoints), and store it in a secrets manager.

---

## API Keys — Issuance, Rotation, Scoping

API keys are the credential type that organizations both over-use (applying them where OAuth tokens would be better) and under-manage (creating them, forgetting them, never rotating them).

A well-designed API key system has four properties:

| Property | What it means | Why it matters |
|----------|--------------|----------------|
| **Scoped** | Each key grants access to a specific resource set | A leaked key can't pivot to other services |
| **Expiring** | Every key has a maximum lifetime | A leaked key eventually becomes useless |
| **Identifiable** | Each key is traceable to an actor and a purpose | Audit logs show WHO did WHAT |
| **Rotatable** | Keys can be replaced without downtime | Rotation can be made automatic |

### Issuance

Generate API keys with a CSPRNG. A common format: `<prefix>_<random>` — the prefix identifies the key type in logs without exposing the secret:

```python
import secrets, hashlib

def issue_api_key(prefix: str) -> tuple[str, str]:
    raw = secrets.token_urlsafe(32)
    key = f"{prefix}_{raw}"               # e.g. "sk_Abc123..."
    digest = hashlib.sha256(key.encode()).hexdigest()
    return key, digest                    # return plaintext once; store only the digest

# Verification
def verify_api_key(submitted: str, stored_digest: str) -> bool:
    return hashlib.sha256(submitted.encode()).hexdigest() == stored_digest
```

Store only the SHA-256 hash in your database — never the key itself. Show the plaintext exactly once to the user at creation, then it's gone. This is the same model GitHub and Stripe use.

### Rotation

Zero-downtime rotation requires a brief overlap period:

```
t=0   issue new_key, mark old_key as "expiring" (still valid)
t+7d  revoke old_key
```

Implement this with a `status` column (`active | expiring | revoked`) and a `revoke_at` timestamp. The auth middleware accepts keys in `active` or `expiring` state, and optionally adds a `Deprecation: true` response header to warn callers who are still on the old key.

### Scoping

Keys should carry their own permission set, not inherit the creating user's full access:

```json
{
  "key_id": "ki_abc123",
  "owner_id": "user_xyz",
  "scopes": ["metrics:read", "alerts:write"],
  "rate_limit": 1000,
  "expires_at": "2027-01-01T00:00:00Z"
}
```

The API enforces `scopes` independently of the user's RBAC. A user who can create billing resources should not be able to issue a key that accesses billing unless you explicitly model `billing:*` as a key scope.

---

## mTLS & Workload Identity (SPIFFE/SPIRE)

Service-to-service authentication with a shared API key has a rotation problem: rotate the key in 15 services simultaneously without downtime. The deeper problem: a shared secret authenticates a key, not an identity — if the key leaks, you don't know which service leaked it.

mTLS solves this by turning every service into a principal with a short-lived X.509 certificate. Both sides of the TLS handshake present certificates; both sides verify the other's chain of trust. No shared secret; certificates rotate automatically.

```
Service A (caller)                   Service B (callee)
──────────────────                   ─────────────────
presents its cert ────── TLS ──────▶ verifies A's cert chain
verifies B's cert ◀──── TLS ──────── presents its cert
mutual: both verified, both identified
```

The certificate is the identity document. What identity does it contain?

### SPIFFE — The Identity Standard

SPIFFE (Secure Production Identity Framework for Everyone) defines a portable identity format: the **SPIFFE ID**, a URI in the form:

```
spiffe://<trust-domain>/<path>
spiffe://corp.com/ns/payments/sa/checkout-api
```

A SPIFFE Verifiable Identity Document (SVID) is an X.509 certificate whose SAN (Subject Alternative Name) contains the SPIFFE URI. Any service that trusts the issuing CA can verify the identity without knowing which IP or hostname the caller is coming from — critical in Kubernetes where pod IPs change constantly.

### SPIRE — The Runtime

SPIRE (SPIFFE Runtime Environment) issues SVIDs automatically based on workload attributes it attests at runtime:

```
┌───────────────────────────────────────────────────────────────────┐
│  SPIRE Server (trust anchor)                                       │
│  - CA root of trust                                               │
│  - stores registration entries (workload → SPIFFE ID mapping)     │
└─────────────────────────────┬─────────────────────────────────────┘
                              │ issues SVID
┌─────────────────────────────▼─────────────────────────────────────┐
│  SPIRE Agent (daemonset on each node)                              │
│  - attests the node (cloud metadata API, TPM, etc.)               │
│  - exposes Workload API socket to pods                            │
└─────────────────────────────┬─────────────────────────────────────┘
                              │ SVID via Workload API
┌─────────────────────────────▼─────────────────────────────────────┐
│  Your workload (pod)                                               │
│  - calls SPIRE Workload API at unix:///tmp/spire-agent/public/api │
│  - receives X.509 SVID + trust bundle                             │
│  - uses the cert for mTLS to peer services                        │
└───────────────────────────────────────────────────────────────────┘
```

SPIRE on Kubernetes: the agent attests a workload by its Kubernetes SA token + namespace + pod labels. The mapping is a registration entry:

```bash
spire-server entry create \
  -parentID spiffe://corp.com/agent/k8s-node \
  -spiffeID spiffe://corp.com/ns/payments/sa/checkout-api \
  -selector k8s:ns:payments \
  -selector k8s:sa:checkout-api \
  -ttl 3600
```

The SVID expires after 1 hour and is automatically renewed by the agent. Compromise of a single cert is bounded by that TTL.

### Istio / Envoy sidecar — mTLS without touching app code

Service meshes like Istio inject a sidecar proxy that intercepts all traffic. The proxy handles mTLS transparent to the application:

```yaml
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: payments-mtls
  namespace: dojo-payments
spec:
  mtls:
    mode: STRICT    # reject any plaintext connection in this namespace
```

With STRICT mode, a pod without a valid SVID cannot send traffic to anything in `dojo-payments`. The app code changes: zero.

---

## Signed Requests (HMAC)

When mTLS is impractical (third-party webhooks, serverless-to-serverless with no cert infra), HMAC-signed requests provide message-level authentication.

The pattern: sender and receiver share a secret key. The sender computes `HMAC-SHA256(key, canonical_message)` and includes it in a header. The receiver recomputes the HMAC over the same canonical form of the request and compares:

```python
import hmac, hashlib, time

def sign_request(method: str, path: str, body: bytes, secret: bytes) -> dict:
    timestamp = str(int(time.time()))
    message = f"{method}\n{path}\n{timestamp}\n".encode() + body
    sig = hmac.new(secret, message, hashlib.sha256).hexdigest()
    return {"X-Timestamp": timestamp, "X-Signature-256": f"sha256={sig}"}

def verify_request(method: str, path: str, body: bytes,
                   timestamp: str, sig_header: str, secret: bytes) -> bool:
    if abs(time.time() - int(timestamp)) > 300:   # ±5 minute replay window
        return False
    expected = sign_request(method, path, body, secret)["X-Signature-256"]
    return hmac.compare_digest(expected, sig_header)   # constant-time comparison
```

Critical details:
- Use `hmac.compare_digest` (constant-time), never `==` — timing attacks on string comparison are real.
- Include a timestamp in the signed message and reject requests older than 5 minutes — without this, a captured request can be replayed indefinitely.
- Define a **canonical form**: which headers to include, in which order. GitHub signs `body` only; Stripe signs `timestamp + "." + body`. Document it explicitly or you'll spend hours debugging mismatches.

Signed requests authenticate the *request* not the *session* — every request is independently verifiable without state. They are not a replacement for TLS; they provide origin integrity on top of it.

---

## Debugging Federation, SSO & Service Auth

The failure modes in federation are often subtle: everything looks fine until a specific user, a specific clock, or a specific assertion path triggers the bug. This table covers the patterns that recur most.

| Symptom | Likely cause | Confirm / fix |
|---------|-------------|---------------|
| SSO succeeds but user gets wrong groups/roles | `groups` claim not mapped; SP reads `email` not group attributes | Decode the SAML assertion or ID token; check AttributeStatement / claims; update SP attribute mapping |
| `Audience Restriction check failed` | SP Entity ID in assertion doesn't match the SP's configured Entity ID | Compare `<AudienceRestriction><Audience>` in the assertion vs `EntityID` in the SP's metadata.xml |
| `Not yet valid` / `Expired` on a SAML assertion | Clock skew between IdP and SP server exceeds the assertion's validity window | `date` on both servers; NTP sync; widen the SP's `allowedClockSkew` setting (e.g., 5 min) |
| Replay attack warning / `InResponseTo mismatch` | SP-initiated nonce (InResponseTo) doesn't match; or IdP-initiated flow with old assertion | Verify SP stores the nonce in session before the redirect; reject IdP-initiated flows |
| API key leaks in logs / error messages | Key passed in URL query param (logged by reverse proxies) | Move key to `Authorization` header; audit access logs; rotate immediately |
| mTLS connection refused with `unknown CA` | SPIRE trust bundle not distributed to the peer; or cert expired | Check `spire-server bundle show`; verify peer's SPIFFE trust domain includes your root CA |
| Signed-request HMAC mismatch | Canonical form differs (body encoding, header casing, or newline trailing) | Log the exact bytes each side signs; compare character-by-character; test with a known-good fixture |
| SCIM provisioning stops syncing | Service token expired or rotated on the app side but not updated in Okta | Check the SCIM token expiry; rotate and update in the IdP admin console |

> **War story.** A high-severity incident at the log pipeline team: a field rotation of the shared API key for an internal metrics endpoint was scheduled for a Sunday. The key was rotated in the secrets manager, but one of 12 consumers — a Fluentd DaemonSet that had baked the old key into a ConfigMap instead of reading from the secrets store — silently started dropping logs. No error was visible for 40 minutes because the DaemonSet's retry buffer masked the 401s. By the time the loss was caught, 40 minutes of production logs had been discarded. The fix took 10 minutes (update the ConfigMap, rolling restart). The lesson took longer: every consumer of a rotated credential must be verified before the old key is revoked, and 401s from a logging agent should page someone at P1 severity, not accumulate silently in a retry buffer. Rotation without confirmation of consumer health is just scheduled breakage.

---

## Checkpoint

You're ready to move on when you can, without looking anything up:

1. Draw the SP-initiated SAML SSO flow and name the three actors, the two main messages, and the four fields in the assertion conditions that the SP must validate.
2. Explain why an OIDC RP must validate `aud`, `iss`, `exp`, signature, and `nonce` — and which one is most commonly skipped in homebrewed implementations.
3. Describe what SCIM is and why a highly privileged SCIM service token should be scoped and rotated differently from a user's session token.
4. State the four properties a well-designed API key system must have (scoped, expiring, identifiable, rotatable) and explain why storing only a SHA-256 hash matters.
5. Explain what a SPIFFE ID is, what a SVID is, and how a SPIRE agent attests a Kubernetes workload to decide which SPIFFE ID to issue it.
6. Describe what STRICT mTLS mode does in Istio and why it means zero app-code changes.
7. Implement an HMAC request verifier in pseudocode that includes timestamp validation and constant-time comparison — explain why both are required.
8. Diagnose a `Not yet valid` SAML assertion rejection without touching either the IdP or SP application code.

➡ Next up: **MFA & Passwordless** — TOTP, WebAuthn/passkeys, and why your SMS second factor is a phishing link away from being useless.
