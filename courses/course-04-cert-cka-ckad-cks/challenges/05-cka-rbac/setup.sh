#!/usr/bin/env bash
# "Least Privilege, Fast" — prepares the namespace; you create the SA/Role/RoleBinding.
set -euo pipefail

NS=dojo-rbac-exam
if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  current kube-context is not 'kind-dojo' — targeting current context anyway."
fi
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
echo "✓ Namespace '$NS' ready. Create ServiceAccount 'viewer' + a Role (get/list/watch pods) + a RoleBinding, then run verify.sh."
