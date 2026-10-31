#!/usr/bin/env bash
# Verifier for "Ship Loki in Monolithic Mode".
# Checks: Helm release 'loki' present, loki Service exists, at least one
# pod with app.kubernetes.io/name=loki is Running.
set -uo pipefail

NS=dojo-lgtm
FLAG='KUBE{loki_single_binary_logs}'

fail() { echo "✗ $1"; exit 1; }

# 1. Namespace must exist
kubectl get ns "$NS" >/dev/null 2>&1 || fail "namespace '$NS' is missing — run setup.sh first"

# 2. Helm release named 'loki' must exist
RELEASE=$(helm -n "$NS" list -q 2>/dev/null | grep -w loki || true)
[ -n "$RELEASE" ] || fail "no Helm release named 'loki' found in $NS — install with: helm install loki grafana/loki -n $NS -f values.yaml"

# 3. A Service whose name contains 'loki' must exist
SVC=$(kubectl -n "$NS" get svc -o name 2>/dev/null | grep loki | head -1 || true)
[ -n "$SVC" ] || fail "no Service matching 'loki' found in $NS — the chart should create one; check: kubectl -n $NS get svc"

# 4. At least one loki pod must be Running
POD_PHASE=$(kubectl -n "$NS" get pods -l "app.kubernetes.io/name=loki" \
  -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)
[ "$POD_PHASE" = "Running" ] || fail "no loki pod in Running phase (found: '${POD_PHASE:-none}') — check: kubectl -n $NS get pods -l app.kubernetes.io/name=loki"

echo "✓ Helm release : $RELEASE"
echo "✓ Service      : $SVC"
echo "✓ Pod phase    : $POD_PHASE"
echo
echo "All checks passed. Submit this flag in the platform:"
echo
echo "    $FLAG"
