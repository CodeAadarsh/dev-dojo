#!/usr/bin/env bash
# Plants the "SLO Recording Rule" scenario: creates the dojo-slo namespace
# and verifies the monitoring CRD is installed.
set -euo pipefail

NS=dojo-slo

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Targeting your current context anyway."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

if ! kubectl get crd prometheusrules.monitoring.coreos.com >/dev/null 2>&1; then
  echo "✗ PrometheusRule CRD not found."
  echo "  Run: bash labs/bootstrap/install-monitoring.sh"
  exit 1
fi

echo
echo "✓ Namespace '$NS' ready."
echo "  Create a PrometheusRule in '$NS' with a recording rule computing an SLI ratio."
echo "  See brief.md for the exact requirements, then run verify.sh."
