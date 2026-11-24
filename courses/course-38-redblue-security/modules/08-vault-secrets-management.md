# Secrets Management with Vault

> **Module 08 · Course 38** — Secrets in Kubernetes Secrets are base64-encoded, not encrypted, and readable by anyone with `get secret` RBAC. HashiCorp Vault is the production-grade secrets manager: dynamic credentials, automatic rotation, full audit trail, and multiple auth backends. This module covers every Vault pattern you'll encounter in K8s.

---

## Why Not Just Use Kubernetes Secrets?

```
K8s Secret lifecycle:
  1. Developer creates: kubectl create secret generic db-pass --from-literal=password=s3cr3t
  2. Stored in etcd: base64("s3cr3t") = "czNjcjN0"  ← NOT encrypted by default
  3. Any pod with get/list secret permission reads it
  4. Same value forever — no rotation
  5. No audit trail: who read this secret, when?

Vault Secret lifecycle:
  1. Vault generates dynamic credential: "user_1a2b3c4d / temp_pass_xyz"
  2. Valid for 1 hour (configurable lease)
  3. Only pods with the correct Vault role can get it (Kubernetes auth method)
  4. Full audit trail: every read logged with pod name, namespace, timestamp
  5. Auto-renewed if pod is still alive, revoked when pod dies
  6. If compromised: revoke the lease, compromised cred stops working immediately
```

---

## Vault Architecture

```
                     Vault Server
                     ─────────────────────────────────────
                     │  Auth Methods (how you log in)      │
                     │  ├── kubernetes: pod SA token        │
                     │  ├── approle: role-id + secret-id    │
                     │  ├── SPIFFE/JWT: SVID token          │
                     │  └── AWS IAM: EC2 identity doc       │
                     │                                      │
                     │  Secrets Engines (what you get out)  │
                     │  ├── kv: static key-value store      │
                     │  ├── database: dynamic DB creds      │
                     │  ├── pki: dynamic X.509 certs        │
                     │  └── transit: encryption-as-service  │
                     │                                      │
                     │  Policies (what you can access)      │
                     │  └── HCL rules: path, capabilities   │
                     └──────────────────────────────────────
                                     │
                     ┌───────────────┼──────────────────┐
                     │               │                  │
              Vault Agent       Vault CSI          ESO (External
              Sidecar           Driver             Secrets Operator)
              ───────────       ──────────         ─────────────────
              Runs in pod       Mounts as           CRD-based sync
              Auto-renews       projected volume    to K8s Secrets
              Writes to         No sidecar needed   GitOps-friendly
              local file
```

---

## Kubernetes Auth Method

Vault uses the pod's K8s ServiceAccount JWT token to authenticate. The pod presents its SA token to Vault, Vault verifies it with the K8s API server, and issues a Vault token with the appropriate policies.

```bash
# Step 1: Enable the K8s auth method in Vault:
vault auth enable kubernetes

# Step 2: Configure it to trust your cluster:
vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc.cluster.local:443" \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
  token_reviewer_jwt="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"

# Step 3: Create a role mapping K8s SA → Vault policy:
vault write auth/kubernetes/role/api-server \
  bound_service_account_names=api-server \
  bound_service_account_namespaces=production \
  policies=api-server-policy \
  ttl=1h
# ^ "Any pod using the api-server SA in the production namespace
#    gets the api-server-policy policy for 1 hour"

# Step 4: Create the policy:
vault policy write api-server-policy - <<'EOF'
# Allow reading the database credentials:
path "database/creds/api-server-db-role" {
  capabilities = ["read"]
}
# Allow reading static config secrets:
path "secret/data/production/api-server/*" {
  capabilities = ["read"]
}
EOF

# From inside the api-server pod — authenticate with Vault:
VAULT_TOKEN=$(curl -s \
  -X POST \
  "https://vault.vault.svc.cluster.local:8200/v1/auth/kubernetes/login" \
  -H "Content-Type: application/json" \
  -d "{\"role\": \"api-server\",
       \"jwt\": \"$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)\"}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['auth']['client_token'])")

echo "Vault token: $VAULT_TOKEN"
```

---

## Dynamic Database Credentials

The database secrets engine generates short-lived database credentials on demand. No static passwords anywhere.

```bash
# Configure the database secrets engine:
vault secrets enable database

vault write database/config/prod-postgres \
  plugin_name=postgresql-database-plugin \
  connection_url="postgresql://{{username}}:{{password}}@postgres.production.svc.cluster.local:5432/appdb" \
  allowed_roles="api-server-db-role" \
  username="vault_root" \
  password="static_root_pass"

# Create a role that generates creds with this SQL:
vault write database/roles/api-server-db-role \
  db_name=prod-postgres \
  creation_statements="
    CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';
    GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA public TO \"{{name}}\";
  " \
  revocation_statements="DROP ROLE IF EXISTS \"{{name}}\";" \
  default_ttl="1h" \
  max_ttl="24h"

# From the api-server pod — get dynamic credentials:
CREDS=$(curl -s \
  -H "X-Vault-Token: $VAULT_TOKEN" \
  "https://vault.vault.svc.cluster.local:8200/v1/database/creds/api-server-db-role")

DB_USER=$(echo "$CREDS" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['username'])")
DB_PASS=$(echo "$CREDS" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['password'])")
# → DB_USER = "v-k8s-api-serv-DGxzYt83pX-1705312800"
# → DB_PASS = "A1b-Cd2eF3g-Hijklmno"
# Valid for 1 hour, then auto-revoked in Postgres
```

What this means: even if an attacker steals the credentials from memory, they expire in 1 hour. And Vault can revoke them immediately if a breach is detected.

```
Attacker steals db creds from env/memory
         │
         ▼
Revoke the lease: vault lease revoke lease-id
         │
         ▼
Postgres immediately drops the role
Credentials no longer work
         │
         ▼
Vault generates new credentials for legitimate pods (auto-renewed by Vault Agent)
```

---

## Vault PKI — Dynamic X.509 Certificates

```bash
# Enable PKI secrets engine:
vault secrets enable pki
vault secrets tune -max-lease-ttl=87600h pki  # 10 year root CA

# Generate root CA:
vault write pki/root/generate/internal \
  common_name="Production Root CA" \
  ttl=87600h

# Create a PKI role for issuing service certs:
vault write pki/roles/production-service \
  allowed_domains="production.svc.cluster.local" \
  allow_subdomains=true \
  max_ttl=72h

# From a pod — request a certificate:
vault write pki/issue/production-service \
  common_name="api-server.production.svc.cluster.local" \
  ttl=24h
# → Returns cert + key + ca_chain
# → Valid for 24 hours, then needs renewal
```

---

## Transit Engine — Encryption as a Service

Pods never handle raw encryption keys. They send plaintext to Vault, get ciphertext back (or vice versa).

```bash
# Enable transit engine:
vault secrets enable transit

# Create an encryption key:
vault write -f transit/keys/api-data-key
# Vault generates and stores the key — your code never sees the raw key

# Encrypt data from a pod:
CIPHERTEXT=$(vault write transit/encrypt/api-data-key \
  plaintext=$(printf '%s' '{"user_id":123,"ssn":"123-45-6789"}' | base64) \
  -field=ciphertext)
# → "vault:v1:ENCRYPTED_BASE64_DATA"
# Store this in your database — not the plaintext

# Decrypt it later:
vault write transit/decrypt/api-data-key \
  ciphertext="$CIPHERTEXT" \
  -field=plaintext | base64 -d
# → {"user_id":123,"ssn":"123-45-6789"}
```

This means: if your database is stolen, the attacker gets ciphertext. The encryption key lives in Vault. Without Vault access (which requires a valid SVID or SA token), the data is unreadable.

---

## Vault Agent Sidecar Pattern

The recommended pattern for K8s: a Vault Agent sidecar runs in each pod and handles authentication and secret renewal automatically.

```yaml
# Pod with Vault Agent sidecar (via annotation-based injection):
apiVersion: v1
kind: Pod
metadata:
  name: api-server
  namespace: production
  annotations:
    vault.hashicorp.com/agent-inject: "true"
    vault.hashicorp.com/role: "api-server"
    # Inject database credentials as a file:
    vault.hashicorp.com/agent-inject-secret-db.env: "database/creds/api-server-db-role"
    vault.hashicorp.com/agent-inject-template-db.env: |
      {{- with secret "database/creds/api-server-db-role" -}}
      export DB_USER="{{ .Data.username }}"
      export DB_PASS="{{ .Data.password }}"
      {{- end -}}
spec:
  serviceAccountName: api-server
  containers:
  - name: app
    image: myapp:latest
    command: ["sh", "-c", "source /vault/secrets/db.env && ./app"]
    # The file /vault/secrets/db.env is written by the Vault Agent sidecar
    # and auto-renewed before it expires
```

```
                     Vault Server
                          ▲
                          │  2. Authenticate (SA token)
                          │  5. Renew before TTL expires
                          │
                     Vault Agent (sidecar in same pod)
                          │
                          │  1. Pod starts
                          │  3. Write secrets to /vault/secrets/
                          │  4. Keep files updated (auto-renewal)
                          ▼
              /vault/secrets/db.env  ← Written by Vault Agent
                          │
              App container reads file
              (source /vault/secrets/db.env)
              → Gets fresh DB credentials
```

---

## External Secrets Operator (ESO)

ESO is a CRD-based alternative: Vault secrets are synced to K8s Secrets on a schedule. No sidecar needed.

```yaml
# SecretStore — tells ESO how to connect to Vault:
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: vault-backend
  namespace: production
spec:
  provider:
    vault:
      server: "https://vault.vault.svc.cluster.local:8200"
      path: "secret"
      version: "v2"
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "api-server"
          serviceAccountRef:
            name: api-server
---
# ExternalSecret — specifies which secret to sync and where to put it:
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: api-server-config
  namespace: production
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-backend
    kind: SecretStore
  target:
    name: api-server-config    # K8s Secret name that gets created
    creationPolicy: Owner
  data:
  - secretKey: database_url     # Key in K8s Secret
    remoteRef:
      key: production/api-server/database
      property: url
```

---

## Checkpoint

You're ready for Module 09 when you can answer:

1. What are the three main components of Vault's architecture (auth methods, secrets engines, policies)?
2. How does the Kubernetes auth method verify a pod's identity?
3. What is a dynamic credential and what is its main security advantage over a static credential?
4. If an attacker steals a dynamic database credential, what should you do, and how quickly does it take effect?
5. What does the transit secrets engine do? What problem does it solve for application developers?
6. What is the Vault Agent sidecar pattern? What does the agent do at pod startup?
7. What is ESO (External Secrets Operator) and when would you prefer it over the Vault Agent sidecar?
8. How does `vault lease revoke` immediately stop an attacker from using stolen credentials?
9. What is the difference between a Vault policy's `read` capability and its `list` capability?
10. Write the Vault CLI command to create a role for the `api-server` SA in the `production` namespace with the `api-server-policy` policy and a 1-hour TTL.

➡ Next: **DevSecOps Pipeline Security** — attacking and securing CI/CD pipelines, from GitHub Actions injection to supply chain controls.
