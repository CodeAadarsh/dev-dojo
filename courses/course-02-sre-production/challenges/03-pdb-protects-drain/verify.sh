#!/usr/bin/env bash
# Verifier for "Budget for Disruption". Confirms a PodDisruptionBudget with
# minAvailable >= 2 actually selects the running 'api' pods, and the Deployment
# is healthy. Prints the flag only when every check passes. Exit 0 = solved.
set -uo pipefail

NS=dojo-pdb
FLAG='KUBE{pdb_protects_the_drain}'

fail() { echo "✗ $1"; exit 1; }

kubectl get ns "$NS" >/dev/null 2>&1 || fail "namespace '$NS' is missing — run setup.sh first"
kubectl -n "$NS" get deploy api >/dev/null 2>&1 || fail "Deployment 'api' not found in $NS — run setup.sh first"

# Find a PDB whose minAvailable is an integer >= 2.
PDB=""
MINAVAIL=""
for p in $(kubectl -n "$NS" get pdb -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  MA=$(kubectl -n "$NS" get pdb "$p" -o jsonpath='{.spec.minAvailable}' 2>/dev/null)
  case "$MA" in
    ''|*[!0-9]*) continue ;;   # skip unset, or non-integer like "50%"
  esac
  if [ "$MA" -ge 2 ] 2>/dev/null; then PDB="$p"; MINAVAIL="$MA"; break; fi
done
[ -n "$PDB" ] || fail "no PodDisruptionBudget in $NS has an integer minAvailable >= 2 (a percentage or maxUnavailable won't pass this challenge)"

# Confirm the selector actually matches live pods. The PDB controller populates
# status.expectedPods with the count of pods its selector matched — a typo'd
# selector leaves this at 0 and silently protects nothing. Give the controller a
# moment to reconcile a freshly-created PDB.
EXPECTED=""
i=1
while [ "$i" -le 10 ]; do
  EXPECTED=$(kubectl -n "$NS" get pdb "$PDB" -o jsonpath='{.status.expectedPods}' 2>/dev/null)
  if [ -n "$EXPECTED" ] && [ "$EXPECTED" != "0" ]; then break; fi
  sleep 1
  i=$((i + 1))
done
if ! [ "${EXPECTED:-0}" -ge 2 ] 2>/dev/null; then
  fail "PDB '$PDB' selects ${EXPECTED:-0} pods — its selector doesn't match the 'api' pods (they carry label app=api); check spec.selector.matchLabels"
fi

# The budget is only meaningful over a healthy app: readyReplicas >= 2.
READY=$(kubectl -n "$NS" get deploy api -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
if ! [ "${READY:-0}" -ge 2 ] 2>/dev/null; then
  fail "Deployment 'api' has ${READY:-0} ready pods (need >= 2) — a budget over an unhealthy app protects nothing; try 'kubectl -n $NS rollout status deploy/api'"
fi

HEALTHY=$(kubectl -n "$NS" get pdb "$PDB" -o jsonpath='{.status.currentHealthy}' 2>/dev/null)
ALLOWED=$(kubectl -n "$NS" get pdb "$PDB" -o jsonpath='{.status.disruptionsAllowed}' 2>/dev/null)

echo "✓ PodDisruptionBudget      : $PDB"
echo "✓ minAvailable             : $MINAVAIL"
echo "✓ selector matches pods    : expectedPods=$EXPECTED (currentHealthy=${HEALTHY:-?})"
echo "✓ deployment ready pods    : $READY"
echo "✓ disruptions allowed now  : ${ALLOWED:-?}  (evictions beyond this are blocked with a 429)"
echo
echo "A node drain now has to proceed pod-by-pod and can never dip below the budget."
echo "Submit this flag in the platform:"
echo
echo "    $FLAG"
