#!/usr/bin/env bash
# Plants the "StorageClass: Retain Your Data" scenario.
set -euo pipefail

NS=dojo-sc

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Targeting your current context anyway."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

echo
echo "✓ Namespace '$NS' ready."
echo "  The default 'standard' StorageClass in kind has reclaimPolicy: Delete."
echo "  Your mission:"
echo "    1. Create a new StorageClass with reclaimPolicy: Retain"
echo "       and allowVolumeExpansion: true."
echo "    2. Create a PVC in '$NS' that uses that StorageClass."
echo "  When the PVC is Bound, run verify.sh."
