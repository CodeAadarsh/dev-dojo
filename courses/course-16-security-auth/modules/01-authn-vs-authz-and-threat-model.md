# AuthN vs AuthZ & the Threat Model

> **Module 01 · Course 16** — Before a single line of auth code, you need a precise threat model. Most security incidents aren't clever zero-days; they're the gap between "we check who you are" and "we forgot to check what you're allowed to do." This module fixes that gap in your mental model.

You've shipped APIs. This is about the invisible contracts every HTTP handler implicitly signs — and what happens when those contracts have holes.

---

## Identity vs Permission: The Two Questions

Authentication and authorization answer different questions. Getting them confused is where the OWASP Top 10 lives.

```
                    ┌─────────────────────────────────────────┐
  every request ──► │ 1. Who are you?   (AuthN)               │
                    │    → prove your identity                  │
                    │    → result: a verified principal         │
                    │                                           │
                    │ 2. Can you do this? (AuthZ)              │
                    │    → check your permissions               │
                    │    → result: allow / deny                 │
                    └─────────────────────────────────────────┘
```

These are **sequential and both mandatory.** Skipping AuthN means you have no principal to check. Skipping AuthZ means every authenticated user can do everything.

| Concept | Answers | Examples |
|---------|---------|---------|
| Authentication (AuthN) | "Are you who you claim to be?" | Password check, JWT signature, mTLS cert, TOTP |
| Authorization (AuthZ) | "Are you allowed to do this specific thing?" | RBAC role check, ownership check, scope validation |
| Principal | The verified identity after AuthN | User ID, service account, OAuth client |
| Subject | The thing being accessed | A resource, endpoint, or operation |
| Policy | The rules that map principal → allowed subjects | RBAC policy, IAM policy, ABAC expression |

### The critical nuance: AuthN proves identity, not intent

A valid JWT proves the token was signed by your key. It does not prove the holder is who they claim to be (stolen token), that the action they're requesting is in scope (missing `aud` check), or that they haven't been revoked since the token was issued (no revocation check). Every auth system needs to handle all three.

---

## OWASP Top 10 — The Auth Hits

The OWASP Top 10 lists the most common web vulnerabilities by frequency and impact. Three of the top five are auth failures. Internalize these, because you'll build against each of them in this course.

| OWASP # | Name | What it means in practice |
|---------|------|--------------------------|
| A01:2021 | Broken Access Control | AuthZ missing or bypassable. #1 by a wide margin since 2021. |
| A02:2021 | Cryptographic Failures | Secrets in plaintext, weak hashing (MD5/SHA1), missing TLS |
| A03:2021 | Injection | SQL/NoSQL injection — still alive and dangerous |
| A04:2021 | Insecure Design | Auth baked into the business layer, not a first-class concern |
| A07:2021 | Identification & Authentication Failures | Broken session management, missing rate-limiting, predictable tokens |

A01 and A07 together cover the majority of authentication-related breaches. The canonical failure pattern: **a developer builds AuthN correctly but adds an AuthZ check as an afterthought — and then forgets to add it at all on a new endpoint six months later.**

### IDOR: the A01 poster child

Insecure Direct Object Reference. An endpoint like `GET /invoices/1042` returns the invoice — but only checks "are you logged in", not "does invoice 1042 belong to *you*". An authenticated attacker iterates IDs and reads every invoice in the database.

```
IDOR pattern:
  logged in as user 99
  GET /invoices/1042     → 200 OK  (invoice belongs to user 44)
  GET /invoices/1043     → 200 OK  (invoice belongs to user 12)
  ...

Fix: always bind the query to the principal's ID:
  SELECT * FROM invoices WHERE id = ? AND user_id = current_user_id
```

---

## Sessions vs Tokens — The Tradeoff Map

Neither is universally better. The right choice depends on your architecture.

```
┌────────────────────────────────────────────────────────────────────┐
│                       SERVER SESSIONS                              │
│                                                                    │
│  client       server                  session store               │
│  ──────       ──────                  ────────────                │
│  POST /login ──────────────────────►  create session              │
│              ◄── Set-Cookie: sid=X ── store {user, roles, exp}    │
│  GET /me                                                           │
│  Cookie: sid=X ────────────────────► lookup(X) → principal        │
│                                                                    │
│  Revocation: O(1), delete the session. Works instantly.           │
│  Scale-out: session store (Redis, DB) becomes a shared dependency. │
└────────────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────────────┐
│                     STATELESS TOKENS (JWT)                         │
│                                                                    │
│  client       auth server            resource server              │
│  ──────       ───────────            ───────────────              │
│  POST /token ──────────────────────► sign JWT(user, roles, exp)   │
│              ◄── {access_token} ──                                │
│  GET /api/data                                                     │
│  Bearer <token> ───────────────────► verify sig + exp → principal │
│                                      no network call needed        │
│                                                                    │
│  Revocation: hard. Token is valid until exp unless you add a       │
│  deny-list (which reintroduces state).                            │
│  Scale-out: every replica can validate independently.              │
└────────────────────────────────────────────────────────────────────┘
```

| Property | Server Sessions | Stateless JWTs |
|----------|----------------|---------------|
| Revocation | Instant (delete from store) | Hard (need a deny-list or short exp) |
| Scale-out | Session store is a shared dependency | No shared state required |
| Server CPU | Cheap (one store lookup) | Cheap (local sig verify) |
| Payload privacy | Session store holds state; client has only an opaque ID | Payload is only base64-encoded — readable by anyone |
| Token size | Cookie: ~50 bytes | JWT: 200–800 bytes per request |
| Best for | Traditional web apps, anything needing instant logout | Stateless microservices, cross-domain APIs, M2M |

**Practical rule:** for user-facing web apps, prefer sessions with secure HttpOnly cookies. For machine-to-machine or multi-service APIs, JWTs with short expiry (< 15 min) + refresh tokens. Hybrid: use sessions for the user-facing tier, JWTs internally between services.

---

## Where Auth Lives in a System

Auth is not a problem you solve in one place and then forget. Every architectural layer has its own auth contract.

```
Internet
  │
  ▼
┌─────────────────────────────────────────────────────────┐
│ Gateway / Ingress (Layer 1)                             │
│  · TLS termination                                      │
│  · Rate limiting / bot detection                        │
│  · JWT/API-key validation (fast, centralized)           │
│  · Does NOT own fine-grained business rules             │
└────────────────────┬────────────────────────────────────┘
                     │ forwards: request + verified-identity header
                     ▼
┌─────────────────────────────────────────────────────────┐
│ Application Service (Layer 2)                           │
│  · Session or token deserialization → principal         │
│  · Coarse-grained AuthZ (roles, feature flags)          │
│  · Owns the business logic for "can user X do action Y" │
└────────────────────┬────────────────────────────────────┘
                     │ calls downstream with propagated identity
                     ▼
┌─────────────────────────────────────────────────────────┐
│ Data / Downstream Services (Layer 3)                    │
│  · Row-level security (PostgreSQL RLS, Firestore rules) │
│  · mTLS between services (zero-trust internal network)  │
│  · Service accounts for service → service calls         │
└─────────────────────────────────────────────────────────┘
```

**Common failure mode:** the gateway validates a JWT and passes an `X-User-Id` header to the app. The app trusts that header without validating the JWT itself. An internal attacker or a misconfigured service can now spoof `X-User-Id` arbitrarily. Rule: **treat every inbound header as untrusted unless you signed it yourself or verified it with a shared secret.**

### Gateway vs App: who validates what

| Concern | Gateway | App |
|---------|---------|-----|
| Token signature valid? | Yes (fast, early) | Optional (re-verify for defense-in-depth) |
| Token not expired? | Yes | Yes (always) |
| User is allowed to call *this endpoint*? | Maybe (coarse) | Yes (authoritative) |
| User owns *this specific resource*? | No — doesn't know business context | Yes |
| Rate-limit by user/IP | Yes | Rarely |

---

## Common Auth Failures in the Wild

### Broken Authentication (OWASP A07)

- No rate-limiting on `/login` — trivially brute-forceable with a word list
- Predictable session IDs (sequential integers, timestamp-based UUIDs)
- Session ID in the URL (`?sessionid=xxx`) — logged by every proxy and browser history
- Missing `Secure` flag → session cookie transmitted over HTTP in a mixed-content page
- No re-authentication before sensitive operations (change password, transfer funds)

### Broken Access Control (OWASP A01)

- IDOR — see above
- **Vertical privilege escalation:** a regular user calls an admin endpoint because there is no role check
- **Horizontal privilege escalation:** user A modifies user B's data via a missing ownership check
- **Forced browsing:** `/admin/users` is "hidden" but not gated
- CORS wildcard on an endpoint that returns user data with credentials

### The Confused Deputy

The confused deputy problem: service B is called by service A, which has been called by a user. Service A is a trusted internal caller, so service B grants it elevated privileges. An attacker can make service A act as their deputy, reaching resources through A that the attacker can't reach directly.

```
Attacker → Service A (trusted by B) → Service B (elevated access)
           ^^^^^^^^^^^^^^^^^^^^^^^^^^^
           the attacker never speaks to B directly;
           they exploit A's trust relationship

Classic web version: SSRF (Server-Side Request Forgery)
  POST /api/fetch-url?url=http://169.254.169.254/latest/meta-data/iam/...
```

The fix is **ambient authority elimination**: service B should act with the user's delegated credential, not with service A's ambient privilege. This is exactly what OAuth2's `on_behalf_of` / token exchange flow solves.

---

## Debugging Auth

When auth behaves unexpectedly, almost every symptom falls into one of four buckets.

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| Authenticated user gets 403 on a resource they should own | AuthZ check exists but doesn't include an ownership predicate | Add `AND owner_id = :principal_id` to the query or check |
| Admin action succeeds for a normal user | Role check is missing on the route handler; gateway checked auth but not the role | Add explicit role assertion in the handler, not just at the gateway |
| Service B returns 200 to a user who has no relationship to the data | Service B trusts an `X-User-Id` header that Service A forwards unchecked | Validate a signed token in Service B; never trust an unsigned forwarded header |
| Rate-limit bypassed by rotating IPs | Rate-limiter keys on IP only | Key on user ID (post-auth) or require CAPTCHA after N failures |
| User logs out but token still works for 30 more minutes | Short-lived JWT, no deny-list | Shorten expiry, or add a revocation check on logout (jti blocklist in Redis) |
| IDOR: user reads another user's data | AuthZ checks only "is authenticated", not "owns resource" | Filter every data query by principal's ID; use UUIDs not sequential integers |

### Debugging the Confused Deputy

> **War story.** On the LGTM pipeline at SAP, we had an internal metadata API that was callable by our log-ingestion service under its Kubernetes ServiceAccount. During an incident review we noticed the service was also reachable from pods in a different namespace via a shared NetworkPolicy gap. Any pod that could make an HTTP call to the metadata service got the ingestion service's response — with the ingestion service's credentials attached. The confused deputy was the ingestion service itself: it had ambient S3 and KMS access, and any pod could invoke it as a proxy. The fix was a namespace-scoped NetworkPolicy (`podSelector` on the ingestion namespace) plus an HMAC signature on every internal metadata request. The gap had been open for four months. We found it because we were building the LGTM tracing course and decided to look at our own traces.

Diagnosis steps for a confused-deputy suspicion:

```bash
# 1. Who can reach the internal service?
kubectl -n dojo-auth get networkpolicy -o yaml   # check ingress selectors

# 2. What identity does the service present to downstream callers?
kubectl -n dojo-auth get pod <ingestion-pod> -o jsonpath='{.spec.serviceAccountName}'

# 3. What can that ServiceAccount actually do?
kubectl auth can-i --list --as=system:serviceaccount:dojo-auth:<sa-name>

# 4. Verify inter-service tokens are bound (not ambient)
# Each downstream call should carry a short-lived token created via TokenRequest API,
# not the ServiceAccount's long-lived automount token.
kubectl -n dojo-auth get secret -o yaml | grep -c "kubernetes.io/service-account-token"
# Should be 0 in a hardened cluster (disable automounting at the ServiceAccount level)
```

---

## Checkpoint

You're ready to move forward when you can answer these without looking:

1. State the exact difference between AuthN and AuthZ in one sentence each. Give a concrete failure case where you get AuthN right but AuthZ wrong.
2. Name three ways a vertical privilege escalation can happen even when a gateway validates a JWT.
3. Draw the three-layer auth architecture (gateway / app / data) and state what each layer is authoritative for.
4. Explain the confused deputy: what is the deputy, who is confused, and what prevents it.
5. Name the two OWASP categories that cover most auth bugs. Give one real example of each from the wild.
6. Choose between sessions and tokens for a user-facing fintech app that requires instant logout. Justify.

➡ Next: **Passwords & Sessions** — implement a correct password hash, build a session that survives rotation, and prove why every session store entry you don't expire is a liability.
