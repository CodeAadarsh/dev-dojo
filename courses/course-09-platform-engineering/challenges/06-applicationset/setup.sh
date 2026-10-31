#!/usr/bin/env bash
# Plants the "ApplicationSet" scenario: creates the dojo-appset namespace and
# warns if ArgoCD is not installed.
set -euo pipefail

NS=dojo-appset

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Targeting your current context anyway."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

if ! kubectl get ns argocd >/dev/null 2>&1; then
  echo "⚠  ArgoCD namespace not found. Install ArgoCD first:"
  echo "   bash labs/bootstrap/install-argocd.sh"
  echo "   (Continuing anyway — setup only creates the target namespace.)"
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

echo
echo "✓ Namespace '$NS' ready."
echo
echo "Your task: create an ArgoCD ApplicationSet in namespace 'argocd' with a list"
echo "  generator (>=2 elements) and destination.namespace=dojo-appset."
echo "Run verify.sh when done."
