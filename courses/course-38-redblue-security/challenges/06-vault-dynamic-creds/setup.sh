#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="dojo-sec-vault"

echo "==> Setting up: Vault Dynamic Credentials"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Deploy Vault in dev mode
kubectl apply -f - << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vault-dev
  namespace: dojo-sec-vault
  labels:
    app: vault
spec:
  replicas: 1
  selector:
    matchLabels:
      app: vault
  template:
    metadata:
      labels:
        app: vault
    spec:
      containers:
      - name: vault
        image: hashicorp/vault:1.15
        args: ["server", "-dev", "-dev-root-token-id=dojo-root-token", "-dev-listen-address=0.0.0.0:8200"]
        ports:
        - containerPort: 8200
        env:
        - name: VAULT_DEV_ROOT_TOKEN_ID
          value: "dojo-root-token"
        - name: VAULT_ADDR
          value: "http://127.0.0.1:8200"
        securityContext:
          capabilities:
            add: ["IPC_LOCK"]
EOF

kubectl apply -f - << 'EOF'
apiVersion: v1
kind: Service
metadata:
  name: vault-svc
  namespace: dojo-sec-vault
spec:
  selector:
    app: vault
  ports:
  - port: 8200
    targetPort: 8200
  type: ClusterIP
EOF

# Client pod to interact with Vault
kubectl apply -f - << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: vault-client
  namespace: dojo-sec-vault
  annotations:
    dojo.vault/purpose: "Interact with Vault dev server to retrieve dynamic credentials"
spec:
  containers:
  - name: client
    image: hashicorp/vault:1.15
    command: ["sh", "-c"]
    args:
    - |
      echo "Vault client pod ready."
      echo ""
      echo "Vault is running at http://vault-svc:8200"
      echo "Root token: dojo-root-token"
      echo ""
      echo "Commands to get the flag:"
      echo "  export VAULT_ADDR=http://vault-svc:8200"
      echo "  export VAULT_TOKEN=dojo-root-token"
      echo "  vault status"
      echo "  vault kv put secret/dojo/challenge flag=KUBE{vault_dynamic_ttl_beats_static_secrets}"
      echo "  vault kv get secret/dojo/challenge"
      echo ""
      echo "The flag is hidden in the KV secret. Write it, then read it back."
      sleep 7200
    env:
    - name: VAULT_ADDR
      value: "http://vault-svc:8200"
    - name: VAULT_TOKEN
      value: "dojo-root-token"
  restartPolicy: Never
EOF

kubectl apply -f - << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: vault-tutorial
  namespace: dojo-sec-vault
data:
  workflow: |
    # Complete Vault KV workflow

    # 1. Authenticate
    export VAULT_ADDR=http://vault-svc:8200
    export VAULT_TOKEN=dojo-root-token
    vault status

    # 2. Write a secret (KV v2 is enabled by default in dev mode)
    vault kv put secret/dojo/challenge flag="KUBE{vault_dynamic_ttl_beats_static_secrets}"

    # 3. Read it back
    vault kv get secret/dojo/challenge

    # 4. Read just the flag field
    vault kv get -field=flag secret/dojo/challenge

    # --- Production pattern: Dynamic DB creds ---

    # Enable database secrets engine
    vault secrets enable database

    # Configure PostgreSQL connection
    vault write database/config/prod-postgres \
      plugin_name=postgresql-database-plugin \
      allowed_roles="app-role" \
      connection_url="postgresql://{{username}}:{{password}}@postgres:5432/appdb" \
      username="vault-admin" \
      password="vault-admin-password"

    # Create a role with TTL
    vault write database/roles/app-role \
      db_name=prod-postgres \
      creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"{{name}}\";" \
      default_ttl="1h" \
      max_ttl="24h"

    # Request credentials (generates new user each time, expires in 1h)
    vault read database/creds/app-role
    # username: v-app-xyz123abc
    # password: A1b2C3d4E5f6G7h8
    # lease_duration: 1h0m0s
    # lease_id: database/creds/app-role/abc123...

    # Revoke before TTL expires (e.g., after job completes)
    vault lease revoke database/creds/app-role/abc123...
EOF

echo ""
echo "==> Setup complete. Vault dev server deploying..."
echo ""
echo "    Wait ~20s for Vault to be ready, then:"
echo "    kubectl exec -it vault-client -n $NAMESPACE -- sh"
echo "    Inside: vault kv put secret/dojo/challenge flag=KUBE{vault_dynamic_ttl_beats_static_secrets}"
echo "    Then:   vault kv get -field=flag secret/dojo/challenge"
