#!/usr/bin/env bash
# "Sidecar Speed Run" — just prepares the namespace; you build the Pod.
set -euo pipefail

NS=dojo-ckad
if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  current kube-context is not 'kind-dojo' — targeting current context anyway."
fi
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
echo "✓ Namespace '$NS' ready. Build a 2-container Pod sharing an emptyDir, then run verify.sh."
