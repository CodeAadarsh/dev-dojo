#!/usr/bin/env bash
# Verifier for "Guarantee It". Reads the live, kubelet-computed QoS verdict from
# pod status (not your YAML) and confirms a Ready 'cache' pod is Guaranteed.
# Prints the flag only when every check passes. Exit 0 = solved, 1 = not yet.
set -uo pipefail

NS=dojo-qos
FLAG='KUBE{requests_equal_limits_is_guaranteed}'

fail() { echo "✗ $1"; exit 1; }

kubectl get ns "$NS" >/dev/null 2>&1 || fail "namespace '$NS' is missing — run setup.sh first"
kubectl -n "$NS" get deploy cache >/dev/null 2>&1 || fail "Deployment 'cache' not found in $NS — run setup.sh first"

# (1) the Deployment must have at least one Ready replica.
READY=$(kubectl -n "$NS" get deploy cache -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
if ! [ "${READY:-0}" -ge 1 ] 2>/dev/null; then
  fail "no pods of 'cache' are Ready yet (found: ${READY:-0}) — wait for the rollout, then re-run"
fi

# (2) there must be a cache pod that is BOTH Ready AND Guaranteed. We scan every
# pod so a lingering old Burstable pod mid-rollout doesn't cause a false pass/fail.
GUARANTEED_POD=""
for p in $(kubectl -n "$NS" get pods -l app=cache -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  QOS=$(kubectl -n "$NS" get pod "$p" -o jsonpath='{.status.qosClass}' 2>/dev/null)
  RDY=$(kubectl -n "$NS" get pod "$p" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  if [ "$QOS" = "Guaranteed" ] && [ "$RDY" = "True" ]; then
    GUARANTEED_POD="$p"
    break
  fi
done

if [ -z "$GUARANTEED_POD" ]; then
  SEEN=$(kubectl -n "$NS" get pods -l app=cache -o jsonpath='{range .items[*]}{.metadata.name}={.status.qosClass} {end}' 2>/dev/null)
  fail "no Ready 'cache' pod is in the Guaranteed QoS class — set requests == limits for BOTH cpu and memory on every container (current: ${SEEN:-none})"
fi

echo "✓ cache readyReplicas      : $READY"
echo "✓ sampled pod              : $GUARANTEED_POD"
echo "✓ status.qosClass          : Guaranteed"
echo
echo "'cache' is now the kernel's LAST OOM target and won't be CPU-throttled below"
echo "its request. Submit this flag in the platform:"
echo
echo "    $FLAG"
