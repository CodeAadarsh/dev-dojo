#!/usr/bin/env bash
# Brings up the 3-node `dojo` kind cluster. Idempotent: safe to re-run.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- preflight -------------------------------------------------------------
if ! docker info >/dev/null 2>&1; then
  echo "✗ Docker daemon is not running."
  echo "  Start Docker Desktop and wait for it to settle, then re-run:"
  echo "      open -a Docker"
  exit 1
fi

if ! command -v kind >/dev/null 2>&1; then
  echo "✗ kind is not installed. Run:"
  echo "      bash $HERE/install-kind.sh"
  exit 1
fi

if ! command -v kubectl >/dev/null 2>&1; then
  echo "✗ kubectl is not installed (brew install kubernetes-cli)."
  exit 1
fi

# --- create ----------------------------------------------------------------
if kind get clusters 2>/dev/null | grep -qx dojo; then
  echo "✓ cluster 'dojo' already exists — reusing it."
else
  echo "Creating kind cluster 'dojo' (1 control-plane + 2 workers)…"
  kind create cluster --config "$HERE/kind-config.yaml"
fi

kubectl config use-context kind-dojo >/dev/null
echo
kubectl cluster-info --context kind-dojo
echo
kubectl get nodes -o wide
echo
echo "✓ Ready. Your context is 'kind-dojo'. Next: bash labs/bootstrap/install-argocd.sh"
