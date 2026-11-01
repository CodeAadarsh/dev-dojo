# Secret Managers & Vault

> **Module 02 · Course 31** — A secret manager is not just a fancier place to store base64. It is an *access broker*: it authenticates the caller, checks a policy, issues a short-lived credential, and keeps an immutable audit trail. This module goes deep on HashiCorp Vault — the model that every other manager (AWS Secrets Manager, GCP Secret Manager, Azure Key Vault) was built to resemble.

You know the problem from Module 01. Now you build the solution. Every concept here maps to a real-world operation you will run against a local Vault server in the challenges.

---

## The Vault Mental Model: Barrier, Seal, and Unseal

Vault has one core invariant: **all data is encrypted before it touches storage**. The encryption key is never stored alongside the data.

```
┌──────────────────────── Vault process ────────────────────────┐
│                                                                │
│   HTTP API ──► Auth ──► Policy check ──► Secret Engine       │
│                                               │               │
│                                        plaintext data         │
│                                               │               │
│                                          ┌────▼────┐          │
│                                          │ Barrier │  encrypt │
│                                          └────┬────┘          │
│                                               │               │
│                                       ciphertext only         │
│                                               │               │
│                                          Storage Backend      │
│                                          (consul/file/raft)   │
└────────────────────────────────────────────────────────────────┘
```

The **barrier** is the encryption layer that wraps every secret engine. It holds an **encryption key** in memory. When Vault starts (or restarts), that key is not available — this is the **sealed** state. In the sealed state, the API returns `503 Vault Sealed` to every request.

### Unseal: Shamir's Secret Sharing

Vault defaults to a Shamir split: the encryption key is split into N key shards, and any M of them (M < N) can reconstruct it. This means:

- No single operator has the full key.
- Vault is sealed on every restart until M operators each supply their shard.
- A compromised shard is useless without M−1 others.

```bash
# production flow (3-of-5 Shamir split)
vault operator unseal <shard-1>   # status: Sealed: true, Unseal Progress: 1/3
vault operator unseal <shard-2>   # status: Sealed: true, Unseal Progress: 2/3
vault operator unseal <shard-3>   # status: Sealed: false  ← now open

# for local dev: a single dev server starts unsealed
docker run -d --name dojo-vault \
  -p 8200:8200 \
  -e VAULT_DEV_ROOT_TOKEN_ID=root \
  -e VAULT_DEV_LISTEN_ADDRESS=0.0.0.0:8200 \
  hashicorp/vault:1.17
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=root
vault status
```

> **Auto-unseal in production.** Manual unseal is operationally painful. Real deployments use **auto-unseal**: Vault retrieves its encryption key from an external KMS (AWS KMS, GCP Cloud KMS, Azure Key Vault) at startup. The trade-off: your KMS becomes the root of trust — guard those IAM policies the way you'd guard root.

---

## Auth Methods

A client authenticates to Vault using an **auth method**. The method validates the caller's identity with an external authority and, on success, issues a Vault token.

| Auth Method | External authority | Typical use |
|-------------|-------------------|-------------|
| `token` | Vault itself (root token) | Bootstrap only — never for services |
| `kubernetes` | kube-apiserver ServiceAccount JWTs | Services running in the cluster |
| `approle` | Vault-issued RoleID + SecretID | CI/CD, services not in k8s |
| `aws` | AWS STS (IAM role) | Services running on EC2/ECS/Lambda |
| `github` | GitHub org membership | Human operators |
| `userpass` | Vault-stored username + password | Humans in dev/staging |
| `jwt/oidc` | Any OIDC provider (Google, Okta) | Human SSO |

The Kubernetes auth method is the one you will use most. It works by having the pod present its ServiceAccount JWT (mounted at `/var/run/secrets/kubernetes.io/serviceaccount/token`) to Vault. Vault calls the kube-apiserver TokenReview API to verify it, then issues a Vault token with the policies tied to the pod's namespace + service account.

```bash
# enable kubernetes auth
vault auth enable kubernetes

# configure the cluster endpoint
vault write auth/kubernetes/config \
  kubernetes_host="https://$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')" \
  kubernetes_ca_cert=@/tmp/ca.crt \
  token_reviewer_jwt="$(kubectl get secret vault-reviewer -o jsonpath='{.data.token}' | base64 -d)"

# create a role: pods in namespace dojo-app using service account app-sa
# can read secrets/data/app/*
vault write auth/kubernetes/role/app-role \
  bound_service_account_names=app-sa \
  bound_service_account_namespaces=dojo-app \
  policies=app-read-policy \
  ttl=1h
```

---

## Policies

A policy is a set of path-based rules. Vault's policy engine is additive: if no policy explicitly grants a capability, the request is denied.

```hcl
# policies/app-read.hcl
# allow reading any secret under secret/data/app/
path "secret/data/app/*" {
  capabilities = ["read"]
}

# allow the app to renew its own token
path "auth/token/renew-self" {
  capabilities = ["update"]
}

# explicitly deny production secrets from this role
path "secret/data/prod/*" {
  capabilities = ["deny"]
}
```

```bash
vault policy write app-read policies/app-read.hcl
vault policy read app-read   # confirm
```

Policy rules are evaluated **most-specific path first**. A deny on `secret/data/prod/*` overrides a blanket `secret/data/*` read.

> **Least privilege here is not optional.** A Vault policy that grants `*` capabilities on `secret/*` is just as bad as no Vault at all. Every role gets the narrowest path pattern that covers its actual secrets, and nothing else.

---

## KV v2 — the Standard Static Secret Engine

KV v2 (key-value version 2) stores arbitrary key-value pairs with full version history. The path layout is:

```
secret/            ← mount point (the engine)
  ├── data/<path>  ← actual secret data (create/read/update)
  └── metadata/<path>  ← version list, soft-delete, destroy
```

```bash
# enable if not already present (dev server has it at 'secret/')
vault secrets enable -path=secret kv-v2

# write a secret
vault kv put secret/app/database \
  host=postgres.dojo-app.svc \
  user=appuser \
  password='hunter2'

# read (returns ciphertext-then-plaintext through the barrier)
vault kv get secret/app/database

# read a specific field
vault kv get -field=password secret/app/database

# read v1 of the secret (before it was last updated)
vault kv get -version=1 secret/app/database

# list all versions
vault kv metadata get secret/app/database
```

Version history means rotation is reversible: if a new credential is wrong, roll back to v1 while you fix it.

---

## Leases: The Key Abstraction

Everything Vault issues — tokens, dynamic credentials, certificates — is wrapped in a **lease**. A lease has:

- `lease_id` — a unique identifier
- `lease_duration` — how long the credential is valid
- `renewable` — whether the lease can be extended
- `lease_renewable_increment` — max time per renewal

When a lease expires, Vault's lease manager calls the secret engine's revocation function. For a dynamic database credential, this means `DROP USER` at the DB. The credential becomes invalid automatically without any human action.

```bash
# see all active leases
vault list sys/leases/lookup/database/creds/

# renew a specific lease before it expires
vault lease renew <lease_id>

# force-revoke immediately (e.g., on a suspected breach)
vault lease revoke <lease_id>

# revoke all leases under a prefix (e.g., rotate all db creds for an app)
vault lease revoke -prefix database/creds/app-role
```

---

## Dynamic Secrets — Database Credentials on Demand

This is the biggest paradigm shift Vault offers. Instead of storing a static password, Vault creates a real database user when a caller asks for it, gives it a lease, and drops the user when the lease expires.

```
App calls: vault read database/creds/app-role
Vault calls: CREATE ROLE "v-token-xxx" WITH PASSWORD '...' VALID UNTIL 'now + 1h'
App receives: username + password, valid for 1 hour
Lease expires: DROP ROLE "v-token-xxx"
```

The static password you were rotating every 90 days no longer exists. What exists instead is a 1-hour-lived user per app-startup — the blast radius of any single leak is bounded to 1 hour, and revocation is instant via `vault lease revoke -prefix`.

```bash
# configure the database secret engine
vault secrets enable database

vault write database/config/postgres \
  plugin_name=postgresql-database-plugin \
  allowed_roles=app-role \
  connection_url="postgresql://{{username}}:{{password}}@localhost:5432/appdb" \
  username=vault_root \
  password='rootpassword'

vault write database/roles/app-role \
  db_name=postgres \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"{{name}}\";" \
  default_ttl=1h \
  max_ttl=24h

# app calls this to get creds
vault read database/creds/app-role
# Key             Value
# lease_id        database/creds/app-role/abc123
# lease_duration  1h
# username        v-token-appname-xyz
# password        A1b2-C3d4-...
```

---

## Transit: Encryption as a Service

The transit engine turns Vault into an encryption oracle. Your application never holds the encryption key — it sends plaintext to Vault and receives ciphertext (or vice versa). The key lives only inside Vault's barrier.

```bash
vault secrets enable transit

vault write -f transit/keys/app-data type=aes256-gcm96

# encrypt
vault write transit/encrypt/app-data \
  plaintext=$(echo -n "card:4111111111111111" | base64)
# ciphertext: vault:v1:8SDd3WHDOjf7mq69CyCqYjBk5NyEkAwoU4cr0...

# decrypt (give ciphertext back to Vault, get plaintext)
vault write transit/decrypt/app-data \
  ciphertext=vault:v1:8SDd3WHDOjf7mq69CyCqYjBk5NyEkAwoU4cr0...
# plaintext: Y2FyZDo0MTExMTExMTExMTExMTEx (base64 of the original)

# rotate the key — old ciphertexts still decrypt, new ones use the new key version
vault write -f transit/keys/app-data/rotate
```

Transit is particularly useful for applications that store encrypted data in a database but should not hold keys in memory — a compromised app server exposes only ciphertext, not the key.

---

## Debugging Vault

### Symptom → Cause → Fix

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `Error initializing: Vault is sealed` on startup | Vault restarted and hasn't been unsealed | Supply unseal shards: `vault operator unseal <shard>`; or check auto-unseal KMS config |
| `Code: 403. Errors: permission denied` | Policy missing the path or capability | `vault policy read <policy>`, verify the path pattern; `vault token capabilities <token> <path>` to debug live |
| `Code: 403. Errors: permission denied` on a correct path | Token has expired or was revoked | `vault token lookup`; renew or re-authenticate |
| `Code: 400. Errors: lease not found or lease is not renewable` | Lease already expired | Re-authenticate to get a fresh lease; adjust `max_ttl` or add renewal logic to the app |
| Dynamic DB creds stop working after some hours | App caches credentials at startup but doesn't renew the lease | Use Vault Agent or a client that calls `vault lease renew` before expiry |
| `dial tcp 127.0.0.1:8200: connect: connection refused` | Vault container not running | `docker ps | grep vault`; `docker start dojo-vault` |
| Every dynamic cred immediately revoked | `max_ttl` shorter than `default_ttl`, or a parent token with a shorter TTL | `vault read database/roles/<role>` — `max_ttl` must be ≥ `default_ttl`; parent token TTL caps child leases |
| Lease explosion — thousands of leases accumulating | Mis-configured renewals causing leases to pile up instead of expire | `vault list sys/leases/lookup/<path>`; `vault lease revoke -prefix <path>`; reduce `max_ttl`; disable renewal if the app always re-authenticates |

### Diagnosing a sealed Vault

```bash
# check status
vault status
# Key             Value
# Sealed          true    ← sealed, nothing works
# Unseal Progress 0/3

# supply shards (interactive)
vault operator unseal

# if using auto-unseal and it fails, check the KMS policy
# for a dev server started above:
docker logs dojo-vault 2>&1 | tail -20
```

### Debugging policy denials

The most powerful Vault debugging tool is the audit device. Enable it first:

```bash
vault audit enable file file_path=/tmp/vault-audit.log

# trigger the denied request, then:
grep '"type":"response"' /tmp/vault-audit.log | \
  python3 -c "import sys,json; [print(json.dumps(json.loads(l)['request']['path'], indent=2)) for l in sys.stdin if json.loads(l).get('response',{}).get('auth',{}).get('policies') or True]" 2>/dev/null | tail -20
```

For live token debugging:

```bash
# what policies does this token have?
vault token lookup

# what can this token do on a path?
vault token capabilities <token> secret/data/app/database
# -> [read]

# what capabilities does a policy grant?
vault policy read app-read
```

### Lease explosion debugging

```bash
# count leases under a path
vault list sys/leases/lookup/database/creds/ 2>/dev/null | wc -l

# revoke all immediately
vault lease revoke -prefix -force database/creds/app-role

# check the renewer configuration in Vault Agent:
# the 'renew_increment' should be less than the lease_duration
# a common mistake: increment > remaining_duration causes Vault to cap at max_ttl
# then the next renewal fails, the app re-auths, accumulating a new lease without revoking the old
```

> **War story.** A microservice was using a Vault Go client with a misconfigured lease renewer: `RenewToken: true` but a hardcoded `Increment` larger than the token's `MaxTTL`. Every renewal attempt silently failed. The service was re-authenticating on each failure, creating a new token and a new database credential, without revoking the old ones. Over 72 hours, the PostgreSQL database had 6,000 orphaned users. The DB started failing new connections (max user limit). The symptom was a 500 on every new request — completely unrelated-looking to the root cause. The fix: set `Increment` to less than the initial lease duration, and add Prometheus metrics on `vault_client_auth_failures_total` so the cascade is visible before it causes an outage. Lease accumulation is silent until it isn't.

---

## Checkpoint

You are ready for the challenges when you can:

1. Explain the sealed state: what information is missing, why the API returns 503, and how to recover.
2. Describe the Shamir unseal in one sentence and state what an auto-unseal trades off.
3. Configure the kubernetes auth method and write a role binding a service account to a policy.
4. Write a policy that grants `read` on `secret/data/app/*` but `deny` on `secret/data/prod/*`.
5. Explain what KV v2's version history enables during a failed rotation.
6. Describe the dynamic database credential lifecycle from `vault read` to `DROP ROLE`.
7. State why the blast radius of a dynamic credential is smaller than a static one.
8. Explain what the transit engine's encryption-as-a-service model achieves that application-held keys cannot.
9. Diagnose a lease explosion: what accumulates, how to detect it, and how to remediate.
10. Recover from a policy 403: the exact sequence of commands to diagnose which path and capability is missing.

➡ Next up: **Secrets on Kubernetes** — you will wire Vault into a real cluster using External Secrets Operator, compare it against sealed-secrets, and close the etcd-plaintext gap with EncryptionConfiguration.
