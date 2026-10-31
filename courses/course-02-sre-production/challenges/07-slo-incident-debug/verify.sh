#!/usr/bin/env bash
# Verifier for "Page at 3am". Confirms the incident is resolved: the Deployment
# is fully Ready, its pods are Running, and the Service has real endpoints.
# Exit 0 = solved, 1 = not yet. Uses only kubectl + POSIX tools (no jq).
set -uo pipefail

NS=dojo-incident
FLAG='KUBE{green_rollout_zero_endpoints}'

fail() { echo "✗ $1"; exit 1; }

kubectl get ns "$NS" >/dev/null 2>&1 || fail "namespace '$NS' is missing — run setup.sh first"
kubectl -n "$NS" get deploy web >/dev/null 2>&1 || fail "Deployment 'web' not found in $NS — run setup.sh first"

# (1) every desired replica must be Ready, not merely scheduled.
DESIRED=$(kubectl -n "$NS" get deploy web -o jsonpath='{.spec.replicas}' 2>/dev/null)
if ! [ "${DESIRED:-0}" -ge 1 ] 2>/dev/null; then
  fail "Deployment 'web' has replicas=${DESIRED:-unset} — don't 'fix' the incident by scaling to zero; keep the workload"
fi

READY=$(kubectl -n "$NS" get deploy web -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
if ! [ "${READY:-0}" -ge "${DESIRED}" ] 2>/dev/null; then
  fail "readyReplicas (${READY:-0}) is below desired ($DESIRED) — pods are running but not Ready; the readiness probe still fails"
fi

# (2) the pods must actually be Running (not Pending/Failed/scaled away).
PHASES=$(kubectl -n "$NS" get pods -l app=web -o jsonpath='{.items[*].status.phase}' 2>/dev/null)
[ -n "$PHASES" ] || fail "no 'web' pods found (label app=web) — the Deployment must keep serving pods"
for p in $PHASES; do
  [ "$p" = "Running" ] || fail "a 'web' pod is in phase '$p', expected Running for all pods"
done

# (3) the Service must have real backends again (endpoints non-empty).
EPS=$(kubectl -n "$NS" get endpoints web -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)
[ -n "$EPS" ] || fail "Service 'web' has no endpoints — Ready pods aren't being selected (check the Service selector and pod readiness)"

EP_COUNT=$(printf '%s\n' "$EPS" | wc -w | tr -d ' ')

echo "✓ desired replicas         : $DESIRED"
echo "✓ readyReplicas            : $READY"
echo "✓ all pods Running         : yes"
echo "✓ Service 'web' endpoints  : $EP_COUNT backend(s)"
echo
echo "The page clears: healthy pods are Ready, the Service has backends, traffic flows."
echo "Submit this flag in the platform:"
echo
echo "    $FLAG"
