#!/usr/bin/env bash
# Installs the Sealed Secrets controller via Helm and creates namespace dojo-sealed.
# Idempotent — re-running is safe.
set -euo pipefail

NS=dojo-sealed
HELM_RELEASE=sealed-secrets
HELM_NS=kube-system

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Targeting your current context anyway."
fi

echo "==> Creating namespace ${NS}..."
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

echo "==> Checking for Sealed Secrets controller..."
if kubectl get deployment sealed-secrets-controller -n "$HELM_NS" 2>/dev/null | grep -q sealed-secrets; then
  echo "    Sealed Secrets controller already installed — skipping Helm install."
else
  echo "==> Installing Sealed Secrets controller via Helm..."
  if ! command -v helm >/dev/null 2>&1; then
    echo "✗ helm not found. Install it: https://helm.sh/docs/intro/install/"
    exit 1
  fi
  helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets 2>/dev/null || true
  helm repo update
  helm upgrade --install "$HELM_RELEASE" sealed-secrets/sealed-secrets \
    --namespace "$HELM_NS" \
    --wait --timeout=3m
fi

echo
echo "✓ Setup complete."
echo
echo "  Namespace '${NS}' is ready."
echo "  Sealed Secrets controller is in namespace '${HELM_NS}'."
echo
echo "Check the controller is running:"
echo "  kubectl get pods -n ${HELM_NS} | grep sealed-secrets"
echo
echo "Next steps:"
echo "  1. Install kubeseal CLI (brew install kubeseal)"
echo "  2. Create plaintext secret manifest (dry-run, do NOT apply):"
echo "       kubectl create secret generic dojo-app-creds \\"
echo "         --namespace=${NS} \\"
echo "         --from-literal=db_password=hunter2 \\"
echo "         --dry-run=client -o yaml > /tmp/plaintext-secret.yaml"
echo "  3. Seal it:"
echo "       kubeseal --format=yaml < /tmp/plaintext-secret.yaml > sealed-secret.yaml"
echo "  4. Apply the SealedSecret:"
echo "       kubectl apply -f sealed-secret.yaml"
echo
echo "Run the verifier when done:"
echo "  bash courses/course-31-secrets-zero-trust/challenges/06-sealed-secret/verify.sh"
