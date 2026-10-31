#!/usr/bin/env bash
# Plants the "Helm Chart with Values Override" scenario.
# Creates namespace dojo-helm2 and verifies helm is available.
set -euo pipefail

NS=dojo-helm2

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Targeting your current context anyway."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

if ! command -v helm >/dev/null 2>&1; then
  echo "✗ helm not found on PATH. Install it before running this challenge."
  echo "  brew install helm   # macOS"
  exit 1
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

echo
echo "✓ Namespace '$NS' ready."
echo "  helm $(helm version --short) is available."
echo
echo "Next steps:"
echo "  1. helm create <chartname>  (in a temp directory outside kube-dojo)"
echo "  2. helm install portal <chartdir> -n $NS --set replicaCount=2 \\"
echo "       --set image.repository=nginx --set image.tag=1.27-alpine"
echo "  3. bash courses/course-09-platform-engineering/challenges/01-helm-with-values/verify.sh"
