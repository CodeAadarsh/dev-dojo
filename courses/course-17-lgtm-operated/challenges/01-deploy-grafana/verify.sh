#!/usr/bin/env bash
# Verifier for "Deploy Grafana with a Live Datasource".
# Checks: Helm release present, labeled datasource ConfigMap present, Deployment ready.
# Prints the flag only when every check passes.
set -uo pipefail

NS=dojo-lgtm
FLAG='KUBE{grafana_datasource_sidecar}'

fail() { echo "✗ $1"; exit 1; }

# 1. Namespace must exist
kubectl get ns "$NS" >/dev/null 2>&1 || fail "namespace '$NS' is missing — run setup.sh first"

# 2. A Helm release whose name contains 'grafana' must exist in the namespace
RELEASE=$(helm -n "$NS" list -q 2>/dev/null | grep grafana || true)
[ -n "$RELEASE" ] || fail "no Helm release matching 'grafana' found in $NS — install with: helm install grafana grafana/grafana -n $NS ..."

# 3. A ConfigMap with label grafana_datasource=1 must exist
CM=$(kubectl -n "$NS" get cm -l grafana_datasource=1 -o name 2>/dev/null || true)
[ -n "$CM" ] || fail "no ConfigMap with label 'grafana_datasource=1' found in $NS — the sidecar needs this label to discover datasources"

# 4. The grafana Deployment must have readyReplicas >= 1
READY=$(kubectl -n "$NS" get deploy -l "app.kubernetes.io/name=grafana" \
  -o jsonpath='{.items[0].status.readyReplicas}' 2>/dev/null || true)
if ! [ "${READY:-0}" -ge 1 ] 2>/dev/null; then
  fail "Grafana Deployment has no ready replicas (found: ${READY:-0}) — check: kubectl -n $NS get pods"
fi

echo "✓ Helm release          : $RELEASE"
echo "✓ Datasource ConfigMap  : $CM"
echo "✓ Grafana ready replicas: $READY"
echo
echo "All checks passed. Submit this flag in the platform:"
echo
echo "    $FLAG"
