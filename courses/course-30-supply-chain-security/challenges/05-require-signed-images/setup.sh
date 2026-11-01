#!/usr/bin/env bash
# Plants the "Require Signed Images with Kyverno" scenario.
# Creates the target namespace and checks for Kyverno presence.
# Idempotent — safe to re-run.
set -euo pipefail

NS="dojo-supplychain"

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Proceeding with current context."
fi

# Create the target namespace
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

# Warn if Kyverno CRD is absent
if ! kubectl get crd clusterpolicies.kyverno.io >/dev/null 2>&1; then
  echo
  echo "⚠  Kyverno CRD not found. Install Kyverno before applying your ClusterPolicy:"
  echo "   kubectl create -f https://github.com/kyverno/kyverno/releases/latest/download/install.yaml"
  echo "   kubectl -n kyverno wait pod --all --for=condition=Ready --timeout=120s"
  echo
else
  echo "✓ Kyverno CRD detected."
fi

echo
echo "✓ Namespace '$NS' is ready."
echo
echo "Mission: create a ClusterPolicy named 'require-signed-images' in Enforce mode"
echo "         with a verifyImages rule scoped to namespace '$NS'."
echo
echo "See the brief for the required policy shape, then apply it:"
echo "   kubectl apply -f require-signed-images.yaml"
echo
echo "Verify with:"
echo "   bash courses/course-30-supply-chain-security/challenges/05-require-signed-images/verify.sh"
