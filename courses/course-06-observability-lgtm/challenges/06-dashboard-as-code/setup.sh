#!/usr/bin/env bash
# Plants the "Dashboard as Code" scenario: creates the dojo-dash namespace.
set -euo pipefail

NS=dojo-dash

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Targeting your current context anyway."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

echo
echo "✓ Namespace '$NS' ready."
echo "  Create a ConfigMap with label 'grafana_dashboard=1' and a data key"
echo "  containing Grafana dashboard JSON (must include a 'panels' array)."
echo "  See brief.md for the exact requirements, then run verify.sh."
