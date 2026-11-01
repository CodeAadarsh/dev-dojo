# The Secrets Problem

> **Module 01 · Course 31** — Before you touch Vault or External Secrets Operator, you need a precise mental model of *why* the current state is broken. This module maps every failure mode: where secrets leak, why rotation is hard, and what "blast radius" actually means in a production incident.

You already know base64 is not encryption — the previous course proved it in a cluster. This module zooms out and asks the harder question: even if a single Secret were encrypted, how many other surfaces does the same credential appear on?

---

## base64 Is Not Encryption (the complete picture)

The one-liner recap: base64 is a transport encoding, not a cryptographic operation. It has no key, no algorithm, no confidentiality guarantee. Decoding it requires nothing but the encoded string.

```bash
# what kubernetes stores in etcd for every Secret field
echo -n 'MyS3cr3tP@ss!' | base64
# -> TXlTM2NyM3RQQHNzIQ==

# what any reader with kubectl get secret permission can do
echo -n 'TXlTM2NyM3RQQHNzIQ==' | base64 -d
# -> MyS3cr3tP@ss!
```

The full chain that causes a breach from a "safely stored" Kubernetes Secret:

```
etcd (base64 only, no encryption at rest by default)
  └── API server (serves to any bearer token with 'get secret')
        └── kubelet (injects into pod env / mounts into /var/run/secrets)
              ├── container env  ← readable via kubectl exec + printenv
              ├── process /proc/1/environ  ← readable if you have shell
              └── crash dump / log if app prints env on startup  ← oops
```

Encryption at rest (`EncryptionConfiguration`) closes the etcd vector. RBAC closes the API-server vector. Neither closes the runtime vectors — those require an external secrets manager that injects the secret as a file and revokes access after the pod exits.

---

## Secret Sprawl

A "secret" is any value that grants access to something: database password, API key, service account token, TLS private key, OAuth client secret, signing key.

In a real service they appear in at least these locations:

| Location | How it got there | Risk |
|----------|-----------------|------|
| `.env` files committed to git | `git add .` accident, `.gitignore` misconfiguration | Permanent — history isn't purged by a `git rm` |
| CI/CD pipeline env vars | Copy-pasted for convenience | Printed by `env`, accessible to any step, leaked in error output |
| Container image (baked in) | `ENV DB_PASS=...` in Dockerfile, or written during build layer | `docker history <image>` exposes every layer; anyone with pull access reads it |
| Kubernetes Secret (base64) | The "standard" approach — but see above | RBAC gap + no encryption at rest = plaintext on disk |
| Application logs | `logger.debug(f"Connecting with {DSN}")` | Log aggregators are often widely readable and retained indefinitely |
| Kubernetes Event / annotation | Helm chart leaks a value into an annotation during templating | Readable without `get secret` — Events are open to all `view` roles by default |

> **The spreadsheet smell.** When a team can't tell you where all copies of their DB password live, they have a sprawl problem. The only fix is a secrets manager with a single source of truth and audit trails.

---

## Long-lived Credentials and Blast Radius

A long-lived credential is one that does not expire on its own and must be revoked manually. This describes: most static API keys, manually-created service account tokens, database users created once at setup time, and TLS certs with 10-year expiry.

The blast radius of a leaked credential has two dimensions:

```
blast radius = (access scope) × (time until revoked)
```

A leaked `EDITOR` API key rotated every 24 hours has a small blast radius: narrow scope, short window. A leaked `root` database password with no rotation policy has an enormous blast radius: full data access, unlimited time.

The standard industry response is:

1. **Short TTLs** — credentials expire automatically, forcing rotation without a human action.
2. **Least privilege** — every credential grants exactly the access its consumer needs and nothing more.
3. **Just-in-time issuance** — dynamic secrets: generate a credential on demand, use it once, let it expire.

HashiCorp Vault's dynamic database secrets (Module 02) implement all three in a single call.

---

## Rotation and Blast Radius Reduction

Rotation is not optional — it is the primary risk-reduction mechanism for long-lived credentials.

The rotation lifecycle for a database password with zero downtime:

```
Step 1: Generate new password at the DB
Step 2: Store new password in the secret manager
Step 3: Deploy new pods reading new password (rolling update)
Step 4: Old pods drain
Step 5: Revoke old password at the DB
```

The gap between steps 2 and 4 is where both old and new credentials are valid — this is called the **dual-active window** and it must be kept as short as possible (minutes, not hours).

> **Rotation is also a fire drill.** If you have never tested rotation under load, you will discover the breakage during an incident. SAP runs rotation drills as part of the release process for every service that touches customer data. The drill exposes which services cache credentials instead of refreshing them on auth failure — those are the ones that need fixing.

---

## Secrets in Code, CI, Logs, and Images

### In code (the git history problem)

```bash
# Finding a secret that was pushed and then deleted
git log --all --full-history -- '*/.env'
git log --all --full-history -p -- '*.py' | grep -i 'password\|secret\|api_key\|token'
```

A secret committed to git is permanently exposed unless the entire repository history is rewritten — which breaks everyone's local clone, breaks PRs, and leaves the secret in every fork and CI cache. The correct answer is: rotate immediately, then optionally rewrite history (BFG Repo Cleaner or `git filter-repo`).

### In CI

Secrets injected as environment variables in GitHub Actions / GitLab CI / Tekton are visible to every step in the job. A misconfigured `echo` or a failing build with verbose output will print them. The mitigation: mark secrets as masked in the CI provider (GitHub Actions masks `${{ secrets.X }}` automatically) and never echo them explicitly.

### In logs

Applications that log the entire config struct on startup will log passwords. Frameworks that log HTTP headers will log Authorization tokens. The fix is a structured logging approach with explicit field allowlists:

```python
# bad
logger.info(f"Starting app with config: {config}")

# good — only log non-sensitive fields
logger.info("Starting app", extra={"db_host": config.db_host, "db_port": config.db_port})
```

### In images

```bash
# every layer is visible — including ENV instructions and RUN commands
docker history myapp:1.0 --no-trunc | grep -iE 'pass|secret|key|token'

# multi-stage builds don't help if the secret is in a final-stage ENV
# the only safe patterns are:
#   1. build-time secrets via --secret (BuildKit, never in image history)
#   2. runtime injection (Vault agent, CSI driver, env from SecretStore)
```

---

## The Secret Lifecycle

Every credential in a well-managed system goes through six stages:

```
CREATE ──► DISTRIBUTE ──► USE ──► ROTATE ──► REVOKE ──► AUDIT
   │            │           │        │          │          │
   └── who      └── how     └── scope └── freq   └── break  └── trail
       created      injected    & blast  &         glass       for
       it &         (env/file/  radius   trigger   procedure   compliance
       approved     sidecar)            (time/                 & forensics
       it                               alert)
```

Most teams nail CREATE and USE. The gaps are ROTATE (painful if credentials are baked-in rather than fetched on startup) and REVOKE (which is hard when you don't know where all copies are — the sprawl problem from earlier).

---

## Debugging The Secrets Problem

### Symptom → Cause → Fix

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Service starts failing after a credential change in the DB | App cached the old credential at startup and does not refresh | Add retry-with-refresh logic on auth failure; mount secret as file and use inotify to reload |
| `git log -p` shows a password that was "deleted" | Deleted in a commit but present in history | Rotate credential immediately; assess exposure window with `git log --pretty=format:"%H %ai" -- <file>`; then BFG or filter-repo to rewrite history |
| CI log shows plaintext token despite masked secret | Step echoes the var explicitly (`echo $TOKEN`) or fails noisily | Remove the echo; mask at CI level; audit all `run:` steps for explicit prints |
| Secret mounted as env var is visible in crash report | App / framework printed `environ` on startup or in exception handler | Mount as file instead of env; strip sensitive keys from the exception context |
| Pod starts fine but DB connection denied after rotation | Old password revoked before rolling update completed | Keep dual-active window: revoke old only after all pods are running on new |
| `docker inspect` shows a build-time password in image config | `ENV PASSWORD=...` or `RUN ... --password=...` in Dockerfile | Use BuildKit `--secret` mount or runtime injection; never bake credentials into layers |

### Detecting a secret in git history

```bash
# install trufflehog (one-time)
pip install trufflehog3

# scan the full history of the current repo
trufflehog filesystem . --json 2>/dev/null | python3 -c \
  "import sys,json; [print(json.dumps(r, indent=2)) for r in map(json.loads, sys.stdin)]"

# lighter option — pure git + grep (no install)
git log --all -p | grep -E '(password|api_key|secret|token)\s*[=:]\s*["\x27]?[A-Za-z0-9+/]{16,}'
```

### Measuring secret age (identifying unrotated credentials)

```bash
# when was a Kubernetes Secret last updated?
kubectl get secret <name> -n <ns> \
  -o jsonpath='{.metadata.annotations.kubectl\.kubernetes\.io/last-applied-configuration}' \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('metadata',{}).get('creationTimestamp','unknown'))"

# simpler — check creation timestamp
kubectl get secret <name> -n <ns> -o jsonpath='{.metadata.creationTimestamp}{"\n"}'
```

> **War story.** A billing service at a previous job had a Stripe test-mode API key committed in a feature branch from 18 months prior. The branch was never merged but the repo was public for 72 hours during an accidental visibility change. The key was rotated only when an automated scanner (added a year later) flagged it. The attacker window: 72 hours public + 18 months in any fork/cache/CI artifact. The lesson: rotate every credential that was ever exposed, regardless of whether you believe it was read. Assuming confidentiality after exposure is wishful thinking — assume breach and rotate.

---

## Checkpoint

You are ready to move on when you can answer these without looking anything up:

1. Explain why `git rm <file>` does not eliminate a leaked secret from a repository.
2. Give two runtime vectors through which a Kubernetes Secret can leak even when etcd is encrypted at rest.
3. Define "blast radius" in one sentence and state its two dimensions.
4. Describe the dual-active window during credential rotation and why it must be short.
5. Name three places a CI secret can appear in plaintext despite being "masked" in the pipeline configuration.
6. State the correct response, in order, when a credential is found in git history.
7. Explain why mounting a secret as an env var is weaker than mounting it as a file.
8. Sketch the six-stage secret lifecycle and name the two stages where most teams have gaps.

➡ Next up: **Secret Managers & Vault** — you'll learn the Vault barrier model, auth methods, KV v2, dynamic database credentials, and transit encryption-as-a-service.
