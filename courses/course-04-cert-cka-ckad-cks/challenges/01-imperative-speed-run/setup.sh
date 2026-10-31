#!/usr/bin/env bash
# Plants the "Imperative Speed Run" scenario: an empty namespace the learner
# fills with a Deployment + Service using only imperative kubectl.
set -euo pipefail

NS=dojo-exam

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Targeting your current context anyway."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

echo
echo "✓ Empty namespace '$NS' is ready — nothing else is planted."
echo
echo "  Your timed task (target: 5 minutes, imperative commands only):"
echo "    • Deployment 'speedy'  — image nginx:1.27-alpine, 3 replicas"
echo "    • ClusterIP Service    — selects 'speedy', port 80"
echo "  all in namespace '$NS'."
echo
echo "  Tip: start the clock, then set your default namespace to skip typing -n:"
echo "    kubectl config set-context --current --namespace=$NS"
echo
echo "  When done, run verify.sh to check your state and reveal the flag."
