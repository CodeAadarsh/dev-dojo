#!/usr/bin/env bash
# Plants the "Fire an Alert" scenario: creates the dojo-alert namespace and
# ensures the monitoring CRD is installed so the learner can create PrometheusRules.
set -euo pipefail

NS=dojo-alert

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Targeting your current context anyway."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

# Confirm the PrometheusRule CRD is installed (kube-prometheus-stack prereq)
if ! kubectl get crd prometheusrules.monitoring.coreos.com >/dev/null 2>&1; then
  echo "✗ PrometheusRule CRD not found."
  echo "  Run: bash labs/bootstrap/install-monitoring.sh"
  exit 1
fi

echo
echo "✓ Namespace '$NS' ready."
echo "  The PrometheusRule CRD is installed."
echo "  Create a PrometheusRule in '$NS' that meets the spec in brief.md, then run verify.sh."
