#!/usr/bin/env bash
# Prepares the "Package It With Helm" scenario. There is nothing to break here —
# the lab just needs an empty namespace to receive your Helm release.
set -euo pipefail

NS=dojo-helm

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Targeting your current context anyway."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

if ! command -v helm >/dev/null 2>&1; then
  echo "⚠  'helm' is not on your PATH — this challenge requires it."
  echo "   macOS: brew install helm   |   https://helm.sh/docs/intro/install/"
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

echo
echo "✓ Namespace '$NS' is ready (nothing planted — you install the release)."
echo
echo "  Fastest path:"
echo "    helm create web"
echo "    helm install web ./web -n $NS --set image.tag=1.27-alpine"
echo "    kubectl -n $NS rollout status deploy/web"
echo
echo "  Then run verify.sh. The release MUST be named 'web'."
