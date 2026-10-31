#!/usr/bin/env bash
# Verifier for "Who Gets Evicted First". Confirms the 'payments' Deployment is
# bound to a real, high-value, non-system PriorityClass and is actually running.
# Prints the flag only when every check passes. Exit 0 = solved, 1 = not yet.
set -uo pipefail

NS=dojo-priority
FLAG='KUBE{priority_decides_eviction_order}'

fail() { echo "✗ $1"; exit 1; }

kubectl get ns "$NS" >/dev/null 2>&1 || fail "namespace '$NS' is missing — run setup.sh first"
kubectl -n "$NS" get deploy payments >/dev/null 2>&1 || fail "Deployment 'payments' not found in $NS — run setup.sh first"

# (1) the pod template must reference a PriorityClass by name.
PCN=$(kubectl -n "$NS" get deploy payments -o jsonpath='{.spec.template.spec.priorityClassName}' 2>/dev/null)
[ -n "$PCN" ] || fail "Deployment 'payments' sets no spec.template.spec.priorityClassName — nothing promotes it above priority 0"

# (3a) it must not be one of the reserved system classes.
case "$PCN" in
  system-*) fail "priorityClassName '$PCN' is a reserved system class — create your OWN high-value class instead" ;;
esac

# (2) that PriorityClass must actually exist (it's cluster-scoped).
kubectl get priorityclass "$PCN" >/dev/null 2>&1 || fail "PriorityClass '$PCN' does not exist — create it (kubectl get priorityclass to list)"

# (3b) and carry a genuinely high integer value.
VAL=$(kubectl get priorityclass "$PCN" -o jsonpath='{.value}' 2>/dev/null)
if ! [ "${VAL:-0}" -ge 100000 ] 2>/dev/null; then
  fail "PriorityClass '$PCN' value must be >= 100000 to count as high priority (found: ${VAL:-unset})"
fi

# (4) the new template must actually be running.
READY=$(kubectl -n "$NS" get deploy payments -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
if ! [ "${READY:-0}" -ge 1 ] 2>/dev/null; then
  fail "no pods of 'payments' are Ready yet (found: ${READY:-0}) — wait for the rollout"
fi

echo "✓ payments.priorityClassName : $PCN"
echo "✓ PriorityClass exists        : yes (cluster-scoped)"
echo "✓ PriorityClass value         : $VAL  (>= 100000, non-system)"
echo "✓ payments readyReplicas      : $READY"
echo
echo "'payments' now outranks the noisy neighbors — it preempts to get scheduled and"
echo "is reaped last under node pressure. Submit this flag in the platform:"
echo
echo "    $FLAG"
