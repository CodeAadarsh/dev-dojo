#!/usr/bin/env bash
# Plants the Loki challenge: ensures the namespace exists and plants a
# placeholder ConfigMap that shows the singleBinary values pattern.
set -euo pipefail

NS=dojo-lgtm

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Proceeding with current context anyway."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

# Hint ConfigMap: shows the shape of the values, NOT a working install
cat <<'YAML' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: loki-install-hint
  namespace: dojo-lgtm
  annotations:
    dojo/purpose: "Hint only — shows the singleBinary values shape"
data:
  values-hint.yaml: |
    # Key values for singleBinary / monolithic mode on kind:
    #
    # deploymentMode: SingleBinary
    # loki:
    #   commonConfig:
    #     replication_factor: 1
    #   storage:
    #     type: filesystem
    # singleBinary:
    #   replicas: 1
    # read:
    #   replicas: 0
    # write:
    #   replicas: 0
    # backend:
    #   replicas: 0
    #
    # helm install loki grafana/loki -n dojo-lgtm -f your-values.yaml
YAML

echo
echo "✓ Namespace '$NS' ready."
echo "  Hint ConfigMap 'loki-install-hint' planted in $NS."
echo "  Install Loki with deploymentMode: SingleBinary, then run verify.sh."
