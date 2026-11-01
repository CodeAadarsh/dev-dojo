#!/usr/bin/env bash
# Sets up namespace dojo-secrets and installs External Secrets Operator via Helm.
# Idempotent — re-running is safe.
set -euo pipefail

NS=dojo-secrets

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Targeting your current context anyway."
fi

echo "==> Creating namespace ${NS}..."
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

echo "==> Checking for External Secrets Operator..."
if kubectl get deployment external-secrets -n external-secrets 2>/dev/null | grep -q external-secrets; then
  echo "    ESO already installed — skipping Helm install."
else
  echo "==> Installing External Secrets Operator via Helm..."
  if ! command -v helm >/dev/null 2>&1; then
    echo "✗ helm not found. Install it: https://helm.sh/docs/intro/install/"
    exit 1
  fi
  helm repo add external-secrets https://charts.external-secrets.io 2>/dev/null || true
  helm repo update
  helm upgrade --install external-secrets external-secrets/external-secrets \
    --namespace external-secrets \
    --create-namespace \
    --set installCRDs=true \
    --wait --timeout=3m
fi

echo
echo "✓ Setup complete."
echo
echo "  Namespace '${NS}' is ready."
echo "  External Secrets Operator is installed in namespace 'external-secrets'."
echo
echo "Your tasks:"
echo "  1. Apply a SecretStore named 'dojo-store' in namespace '${NS}'."
echo "     Use the 'fake' provider with a data entry for key '/dojo/app/api-key'."
echo "  2. Apply an ExternalSecret named 'dojo-app-secret' in namespace '${NS}'."
echo "     secretStoreRef.name: dojo-store, target.name: dojo-synced-app"
echo "     data: secretKey 'api_key' -> remoteRef.key '/dojo/app/api-key'"
echo
echo "Run the verifier when done:"
echo "  bash courses/course-31-secrets-zero-trust/challenges/05-external-secret-sync/verify.sh"
