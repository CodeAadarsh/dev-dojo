#!/usr/bin/env bash
# Installs Argo CD into the cluster and prints how to reach the UI + the
# initial admin password. Idempotent.
set -euo pipefail

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  current context is not kind-dojo; run: kubectl config use-context kind-dojo"
fi

echo "Creating namespace 'argocd'…"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

echo "Installing Argo CD (stable manifests)…"
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "Waiting for argocd-server to become available (up to 3 min)…"
kubectl -n argocd rollout status deploy/argocd-server --timeout=180s

echo
echo "────────────────────────────────────────────────────────"
echo " Argo CD is up. To use it:"
echo
echo "   1. Port-forward the UI:"
echo "        kubectl -n argocd port-forward svc/argocd-server 8081:443"
echo "      then open  https://localhost:8081  (accept the self-signed cert)"
echo
echo "   2. Log in as 'admin' with this initial password:"
printf "        "
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "(secret not found yet — retry in a few seconds)"
echo
echo
echo "   3. (optional) install the CLI:  brew install argocd"
echo "────────────────────────────────────────────────────────"
