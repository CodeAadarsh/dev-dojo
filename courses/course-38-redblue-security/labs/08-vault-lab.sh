#!/usr/bin/env bash
# Module 08 — Secrets Management with Vault Lab
# Installs Vault in dev mode and creates a demo app with a hardcoded secret to replace
set -euo pipefail

NS="dojo-lab-vault"

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

# Install Vault if not present
if ! helm list -n vault | grep -q "^vault"; then
  echo "Installing Vault via Helm (dev mode)..."
  helm repo add hashicorp https://helm.releases.hashicorp.com --force-update
  helm repo update

  helm install vault hashicorp/vault \
    --namespace vault \
    --create-namespace \
    --set server.dev.enabled=true \
    --set server.dev.devRootToken="root" \
    --set injector.enabled=true \
    --wait --timeout=5m
  echo "Vault installed."
else
  echo "Vault already installed."
fi

# Demo app with a hardcoded secret (the bad pattern to replace)
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
  namespace: $NS
data:
  config.yaml: |
    database:
      host: "prod-db.internal"
      port: 5432
      # BAD: hardcoded credentials
      username: "app_user"
      password: "super-secret-db-pass-do-not-share"
    app:
      port: 8080
      env: production
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-app
  namespace: $NS
  labels:
    app: demo-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: demo-app
  template:
    metadata:
      labels:
        app: demo-app
      annotations:
        # After Vault is configured, you'll add these annotations for agent injection
        # vault.hashicorp.com/agent-inject: "true"
        # vault.hashicorp.com/role: "demo-app"
        # vault.hashicorp.com/agent-inject-secret-config.yaml: "secret/data/demo-app/db"
    spec:
      containers:
      - name: app
        image: alpine:3.20
        command: ["sh", "-c", "cat /app/config.yaml; sleep 86400"]
        env:
        # BAD: hardcoded in env too
        - name: DB_PASSWORD
          value: "super-secret-db-pass-do-not-share"
        volumeMounts:
        - name: config
          mountPath: /app
        resources:
          limits:
            cpu: "100m"
            memory: "64Mi"
      volumes:
      - name: config
        configMap:
          name: app-config
EOF

echo "Vault lab ready. Namespace: $NS"
echo ""
echo "Vault UI: kubectl port-forward svc/vault -n vault 8200:8200"
echo "  → http://localhost:8200 (token: root)"
echo ""
echo "Exercise: Replace the hardcoded DB_PASSWORD with Vault dynamic credentials"
echo ""
echo "Steps:"
echo "  1. kubectl exec vault-0 -n vault -- vault kv put secret/demo-app/db password=vault-managed-pass"
echo "  2. Create a Vault role and policy for demo-app SA"
echo "  3. Enable Vault agent injection via pod annotations"
echo "  4. Verify: kubectl exec deploy/demo-app -n $NS -- cat /vault/secrets/config.yaml"
