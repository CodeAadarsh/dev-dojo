#!/usr/bin/env bash
# Verifier for "Probe the Depths". Inspects live cluster state; prints the flag
# only when both probes are present and every pod is Ready. Exit 0 = solved, 1 = not yet.
set -uo pipefail

NS=dojo-probes
FLAG='KUBE{readiness_gates_traffic_liveness_restarts}'

fail() { echo "✗ $1"; exit 1; }

kubectl get ns "$NS" >/dev/null 2>&1 || fail "namespace '$NS' is missing — run setup.sh first"
kubectl -n "$NS" get deploy web >/dev/null 2>&1 || fail "Deployment 'web' not found in $NS"

READINESS=$(kubectl -n "$NS" get deploy web -o jsonpath='{.spec.template.spec.containers[0].readinessProbe}' 2>/dev/null)
[ -n "$READINESS" ] || fail "container[0] needs a readinessProbe (httpGet / on port 80)"

LIVENESS=$(kubectl -n "$NS" get deploy web -o jsonpath='{.spec.template.spec.containers[0].livenessProbe}' 2>/dev/null)
[ -n "$LIVENESS" ] || fail "container[0] needs a livenessProbe (httpGet / on port 80)"

DESIRED=$(kubectl -n "$NS" get deploy web -o jsonpath='{.spec.replicas}' 2>/dev/null)
DESIRED=${DESIRED:-0}
READY=$(kubectl -n "$NS" get deploy web -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
READY=${READY:-0}

if ! [ "$DESIRED" -ge 1 ] 2>/dev/null; then
  fail "Deployment 'web' has no desired replicas (found: $DESIRED)"
fi
if ! [ "$READY" -ge "$DESIRED" ] 2>/dev/null; then
  fail "fewer pods Ready than desired ($READY/$DESIRED) — is your livenessProbe too aggressive and crashlooping the pods?"
fi

echo "✓ Deployment 'web'         : present"
echo "✓ readinessProbe present   : yes"
echo "✓ livenessProbe present    : yes"
echo "✓ pods Ready / desired     : $READY/$DESIRED"
echo
echo "All health-check requirements passed. Submit this flag in the platform:"
echo
echo "    $FLAG"
