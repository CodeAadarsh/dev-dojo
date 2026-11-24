# Vault Dynamic Credentials — Solution

## Steps

### Step 1: Exec into the Vault client pod

```bash
kubectl exec -it vault-client -n dojo-sec-vault -- sh
```

### Step 2: Check Vault status

```bash
vault status
```

Expected output:
```
Key             Value
---             -----
Seal Type       shamir
Initialized     true
Sealed          false
Total Shares    1
Threshold       1
Version         1.15.x
Dev Mode        true
...
```

### Step 3: Write the challenge secret

```bash
vault kv put secret/dojo/challenge flag="KUBE{vault_dynamic_ttl_beats_static_secrets}"
```

Output:
```
== Secret Path ==
secret/data/dojo/challenge

======= Metadata =======
Key                Value
---                -----
created_time       2026-11-25T17:45:00Z
custom_metadata    <nil>
deletion_time      n/a
destroyed          false
version            1
```

### Step 4: Read the flag back

```bash
vault kv get -field=flag secret/dojo/challenge
```

**Flag:** `KUBE{vault_dynamic_ttl_beats_static_secrets}`

---

## Why Dynamic Secrets Are Better

| Dimension | Static Secrets | Vault Dynamic |
|-----------|---------------|---------------|
| Rotation | Manual, often never | Automatic (TTL-based) |
| Blast radius if leaked | Permanent access | Access limited to TTL (1h default) |
| Audit trail | None | Full: who requested, when, which lease |
| Revocation | Manual DB password change | `vault lease revoke <lease-id>` |
| Uniqueness | Shared credential | Per-request username, unique password |

---

## Production Architecture

```
                           ┌────────────────────────────────┐
   App Pod                 │       HashiCorp Vault (HA)      │
   ─────────               │                                  │
   SA token ─────────────► │  K8s Auth: verify JWT signature  │
                           │       ↓                          │
                           │  Policy: allow db/creds/app      │
                           │       ↓                          │
                           │  Database Secrets Engine          │
                           │  CREATE USER v-app-xyz123         │
                           │  GRANT SELECT ON ... TO user      │
                           │  VALID UNTIL now + 1h             │
                           │       ↓                          │
                           │  Returns: username, password,     │
                           │           lease_id, ttl           │
                           └────────────────────────────────-─┘
                                        │
                                        ▼
                              App connects to PostgreSQL
                              with dynamic creds
                                        │
                              1 hour later: Vault revokes
                              DB user is DROPPED automatically
```

---

## Vault Agent Sidecar (Kubernetes-Native Integration)

Instead of calling Vault's HTTP API, inject credentials as files via the Vault Agent sidecar:

```yaml
# Pod annotation — Vault Agent Injector handles the rest
annotations:
  vault.hashicorp.com/agent-inject: "true"
  vault.hashicorp.com/role: "app-role"
  vault.hashicorp.com/agent-inject-secret-db-creds: "database/creds/app-role"
  vault.hashicorp.com/agent-inject-template-db-creds: |
    {{- with secret "database/creds/app-role" -}}
    username={{ .Data.username }}
    password={{ .Data.password }}
    {{- end }}
```

Vault Agent injects the secret at `/vault/secrets/db-creds` and renews it automatically before expiry. Zero application code changes needed.
