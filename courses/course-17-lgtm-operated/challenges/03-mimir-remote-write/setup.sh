#!/usr/bin/env bash
# Plants the Mimir challenge: namespace + a stub remote_write ConfigMap that
# is missing the X-Scope-OrgID header so the learner must author it correctly.
set -euo pipefail

NS=dojo-lgtm

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Proceeding with current context anyway."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

# Stub ConfigMap: has the URL but is missing X-Scope-OrgID.
# The learner must create a correct 'prometheus-remote-write-config' ConfigMap.
cat <<'YAML' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: prometheus-remote-write-stub
  namespace: dojo-lgtm
  annotations:
    dojo/hint: "Stub only. Create 'prometheus-remote-write-config' with the OrgID."
data:
  remote_write.yaml: |
    # INCOMPLETE — missing X-Scope-OrgID header
    remote_write:
      - url: http://mimir-nginx.dojo-lgtm.svc/api/v1/push
        # TODO: add the multi-tenant header here
YAML

echo
echo "✓ Namespace '$NS' ready."
echo "  Stub ConfigMap 'prometheus-remote-write-stub' planted — it is deliberately"
echo "  missing the X-Scope-OrgID header. Your tasks:"
echo "  1. helm install mimir grafana/mimir-distributed -n $NS -f your-values.yaml"
echo "  2. Create ConfigMap 'prometheus-remote-write-config' with the correct"
echo "     remote_write config including X-Scope-OrgID"
echo "  3. Run verify.sh"
