#!/usr/bin/env bash
# "Wire It Up" — prepares the namespace; you create the ConfigMap, Secret, and Deployment.
set -euo pipefail

NS=dojo-wire
if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  current kube-context is not 'kind-dojo' — targeting current context anyway."
fi
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
echo "✓ Namespace '$NS' ready. Create ConfigMap 'app-config' + Secret 'app-secret' + Deployment 'app'"
echo "  (envFrom the ConfigMap, mount the Secret as a volume), then run verify.sh."
