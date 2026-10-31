#!/usr/bin/env bash
# Verifier for "Make It Survive". Inspects live cluster state; prints the flag
# only when every resilience check passes. Exit 0 = solved, 1 = not yet.
set -uo pipefail

NS=dojo-resilient
FLAG='KUBE{readiness_plus_pdb_equals_zero_downtime}'

fail() { echo "✗ $1"; exit 1; }

kubectl get ns "$NS" >/dev/null 2>&1 || fail "namespace '$NS' is missing — run setup.sh first"
kubectl -n "$NS" get deploy web >/dev/null 2>&1 || fail "Deployment 'web' not found in $NS"

REPLICAS=$(kubectl -n "$NS" get deploy web -o jsonpath='{.spec.replicas}' 2>/dev/null)
if ! [ "${REPLICAS:-0}" -ge 3 ] 2>/dev/null; then
  fail "Deployment 'web' needs >= 3 replicas (found: ${REPLICAS:-none})"
fi

PROBE=$(kubectl -n "$NS" get deploy web -o jsonpath='{.spec.template.spec.containers[0].readinessProbe}' 2>/dev/null)
[ -n "$PROBE" ] || fail "container needs a readinessProbe"

MAXU=$(kubectl -n "$NS" get deploy web -o jsonpath='{.spec.strategy.rollingUpdate.maxUnavailable}' 2>/dev/null)
[ "$MAXU" = "0" ] || fail "rolling update must set maxUnavailable: 0 (found: ${MAXU:-unset})"

REQ=$(kubectl -n "$NS" get deploy web -o jsonpath='{.spec.template.spec.containers[0].resources.requests}' 2>/dev/null)
[ -n "$REQ" ] || fail "container needs resource requests (cpu + memory)"

PDB=$(kubectl -n "$NS" get pdb -o name 2>/dev/null)
[ -n "$PDB" ] || fail "a PodDisruptionBudget protecting 'web' is required"

READY=$(kubectl -n "$NS" get deploy web -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
if ! [ "${READY:-0}" -ge 3 ] 2>/dev/null; then
  fail "fewer than 3 pods are Ready (found: ${READY:-0}) — is your readinessProbe passing?"
fi

echo "✓ replicas >= 3            : $REPLICAS"
echo "✓ readinessProbe present   : yes"
echo "✓ maxUnavailable           : 0"
echo "✓ resource requests set    : yes"
echo "✓ PodDisruptionBudget      : ${PDB}"
echo "✓ pods Ready               : $READY"
echo
echo "All resilience checks passed. Submit this flag in the platform:"
echo
echo "    $FLAG"
