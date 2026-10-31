#!/usr/bin/env bash
# Plants the Grafana challenge: creates the namespace and a stub ConfigMap
# that deliberately lacks the required label, so the learner has to fix it
# or create a properly-labeled one.
set -euo pipefail

NS=dojo-lgtm

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Proceeding with current context anyway."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

# Plant a stub ConfigMap WITHOUT the magic label — learner must add the label
# or create a new properly-labeled one alongside their Helm install.
cat <<'YAML' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-datasource-stub
  namespace: dojo-lgtm
  annotations:
    dojo/hint: "This ConfigMap is missing something. Check the brief."
data:
  prometheus.yaml: |
    apiVersion: 1
    datasources:
      - name: Prometheus
        type: prometheus
        access: proxy
        url: http://prometheus-operated.dojo-lgtm.svc:9090
        isDefault: true
YAML

echo
echo "✓ Namespace '$NS' ready."
echo "  A stub ConfigMap 'grafana-datasource-stub' has been planted — it is missing"
echo "  the required label. Your tasks:"
echo "  1. helm install grafana grafana/grafana -n $NS (with sidecar enabled)"
echo "  2. Create (or label) a ConfigMap with 'grafana_datasource=1'"
echo "  3. Run verify.sh"
