#!/usr/bin/env bash
# Plants the "Stateful Identity" scenario: creates the dojo-sts namespace.
# The learner creates the StatefulSet, headless Service, and PVCs from scratch.
set -euo pipefail

NS=dojo-sts

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Targeting current context anyway."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

echo
echo "✓ Namespace '$NS' ready."
echo
echo "  Your mission:"
echo "  1. Create a headless Service (clusterIP: None) in $NS"
echo "  2. Create a StatefulSet (nginx:1.27-alpine, 3 replicas) in $NS with:"
echo "       spec.serviceName  → name of your headless Service"
echo "       volumeClaimTemplates[0].metadata.name: data  (1Gi RWO, standard SC)"
echo "       a readinessProbe on port 80 path /"
echo "  3. Wait for all 3 pods to become Ready and 3 PVCs to become Bound"
echo "  4. Run verify.sh"
