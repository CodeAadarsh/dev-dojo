#!/usr/bin/env bash
# Verifier for "The CrashLoop Mystery". Passes only when Deployment 'api' in
# dojo-crash is genuinely healthy: >=1 ready, all pods Running, zero restarts.
# Exit 0 = solved, 1 = not yet.
set -uo pipefail

NS=dojo-crash
FLAG='KUBE{crashloopbackoff_is_a_symptom}'

fail() { echo "✗ $1"; exit 1; }

kubectl get ns "$NS" >/dev/null 2>&1 || fail "namespace '$NS' is missing — run setup.sh first"
kubectl -n "$NS" get deploy api >/dev/null 2>&1 || fail "Deployment 'api' not found in $NS"

READY=$(kubectl -n "$NS" get deploy api -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
if ! [ "${READY:-0}" -ge 1 ] 2>/dev/null; then
  fail "Deployment 'api' has no Ready replicas (found: ${READY:-0}) — the container is still failing to start"
fi

# There must actually be pods selected by app=api.
PHASES=$(kubectl -n "$NS" get pods -l app=api -o jsonpath='{.items[*].status.phase}' 2>/dev/null)
[ -n "$PHASES" ] || fail "no pods with label app=api found in $NS"

# Every selected pod must be Running — catch Pending / Failed / Error.
for p in $PHASES; do
  [ "$p" = "Running" ] || fail "a pod is in phase '$p' (expected Running) — not fully recovered yet"
done

# A CrashLoopBackOff shows up as a container waiting with that reason.
WAITING=$(kubectl -n "$NS" get pods -l app=api -o jsonpath='{.items[*].status.containerStatuses[*].state.waiting.reason}' 2>/dev/null)
case " $WAITING " in
  *CrashLoopBackOff*) fail "a container is still in CrashLoopBackOff — the root cause is not fixed" ;;
  *Error*)            fail "a container is in state Error — the root cause is not fixed" ;;
esac

# The fix must produce fresh, stable pods: restartCount 0 on every running pod.
RESTARTS=$(kubectl -n "$NS" get pods -l app=api -o jsonpath='{.items[*].status.containerStatuses[*].restartCount}' 2>/dev/null)
for r in $RESTARTS; do
  if ! [ "${r:-0}" -eq 0 ] 2>/dev/null; then
    fail "a running pod has restartCount=$r — roll out cleanly so the healthy pods start from 0 (kubectl -n $NS rollout restart deploy/api)"
  fi
done

echo "✓ readyReplicas >= 1       : $READY"
echo "✓ all app=api pods Running : yes"
echo "✓ no CrashLoopBackOff/Error: yes"
echo "✓ restarts on running pods : 0"
echo
echo "The CrashLoop is solved and the pods are stable. Submit this flag in the platform:"
echo
echo "    $FLAG"
