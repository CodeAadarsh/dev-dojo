#!/usr/bin/env bash
# Plants the "Provision a Tenant Namespace" scenario.
# Creates the target namespace and the ServiceAccount the learner must bind.
set -euo pipefail

NS=dojo-tenant-a

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Targeting your current context anyway."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$NS" create serviceaccount tenant-operator \
  --dry-run=client -o yaml | kubectl apply -f -

echo
echo "✓ Namespace '$NS' ready."
echo "✓ ServiceAccount 'tenant-operator' created in '$NS'."
echo
echo "Your task: add a ResourceQuota, a LimitRange, and a RoleBinding that grants"
echo "  tenant-operator the 'edit' ClusterRole in this namespace only."
echo "Run verify.sh when done."
