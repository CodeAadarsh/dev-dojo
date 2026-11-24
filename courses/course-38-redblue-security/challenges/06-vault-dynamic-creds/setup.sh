#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="dojo-sec-vault"

echo "==> Setting up: Vault Dynamic Credentials"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Deploy Vault in dev mode
kubectl apply -f - << 'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vault
  namespace: dojo-sec-vault
---
apiVersion: v1
kind: Service
metadata:
  name: vault
  namespace: dojo-sec-vault
spec:
  selector:
    app: vault
  ports:
  - name: api
    port: 8200
    targetPort: 8200
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vault
  namespace: dojo-sec-vault
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
      serviceAccountName: vault
      containers:
      - name: vault
        image: hashicorp/vault:1.16
        command: ["vault", "server", "-dev", "-dev-root-token-id=root", "-dev-listen-address=0.0.0.0:8200"]
        ports:
        - containerPort: 8200
        env:
        - name: VAULT_DEV_ROOT_TOKEN_ID
          value: "root"
        - name: VAULT_ADDR
          value: "http://127.0.0.1:8200"
        securityContext:
          capabilities:
            add: ["IPC_LOCK"]
EOF

echo "[*] Waiting for Vault pod to be ready..."
kubectl wait --for=condition=Ready pod -l app=vault -n "$NAMESPACE" --timeout=120s

# Configure Vault via a setup Job
kubectl apply -f - << 'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: vault-setup
  namespace: dojo-sec-vault
spec:
  template:
    spec:
      restartPolicy: OnFailure
      containers:
      - name: setup
        image: hashicorp/vault:1.16
        env:
        - name: VAULT_ADDR
          value: "http://vault.dojo-sec-vault.svc:8200"
        - name: VAULT_TOKEN
          value: "root"
        command:
        - sh
        - -c
        - |
          set -e
          sleep 5

          # Enable KV secrets engine
          vault secrets enable -path=secret kv-v2 2>/dev/null || true

          # Store the flag
          vault kv put secret/dojo/flag \
            value="KUBE{vault_leases_expire_creds_dont}" \
            hint="Dynamic credentials rotate automatically. Static ones do not."

          # Enable mock database secrets engine
          vault secrets enable database 2>/dev/null || true

          # Configure a mock postgres connection
          # Uses a fake connection_url — in a real environment this would point to actual DB
          vault write database/config/app-db \
            plugin_name=postgresql-database-plugin \
            allowed_roles="app-role" \
            connection_url="postgresql://{{username}}:{{password}}@fake-postgres.dojo-sec-vault.svc:5432/appdb" \
            username="vault" \
            password="fake" 2>/dev/null || true

          # Create a role with short TTL
          vault write database/roles/app-role \
            db_name=app-db \
            creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';" \
            revocation_statements="DROP ROLE IF EXISTS \"{{name}}\";" \
            default_ttl="60s" \
            max_ttl="5m" 2>/dev/null || true

          echo "Vault setup complete"
EOF

echo "[*] Waiting for Vault setup job to complete..."
kubectl wait --for=condition=complete job/vault-setup -n "$NAMESPACE" --timeout=120s 2>/dev/null || \
  echo "[!] Setup job may still be running, continuing..."

echo ""
echo "==> Setup complete."
echo ""
echo "    Port-forward: kubectl port-forward -n $NAMESPACE svc/vault 8200:8200 &"
echo "    Root token:   VAULT_TOKEN=root"
echo "    Read flag:    vault kv get secret/dojo/flag"
echo ""
echo "    Note: The database/creds/app-role endpoint requires a real PostgreSQL."
echo "    If it errors, skip to 'vault kv get secret/dojo/flag' directly."
