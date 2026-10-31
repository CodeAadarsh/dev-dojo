#!/usr/bin/env bash
# Verifier for "Pin the Pod". Confirms the pinme Deployment has REQUIRED
# nodeAffinity for tier=gold AND that every running pod actually landed on the
# gold node. Prints the flag only when all checks pass. Exit 0 = solved, 1 = not.
set -uo pipefail

NS=dojo-sched
FLAG='KUBE{node_affinity_pins_the_pod}'

fail() { echo "✗ $1"; exit 1; }

kubectl get ns "$NS" >/dev/null 2>&1 || fail "namespace '$NS' is missing — run setup.sh first"
kubectl -n "$NS" get deploy pinme >/dev/null 2>&1 || fail "Deployment 'pinme' not found in $NS"

# Which node is gold right now?
GOLD=$(kubectl get nodes -l tier=gold -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -n "$GOLD" ] || fail "no node is labelled tier=gold — re-run setup.sh"

# 1) Required nodeAffinity expression on key=tier including value gold.
MEXPR=$(kubectl -n "$NS" get deploy pinme \
  -o jsonpath='{.spec.template.spec.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[*].matchExpressions[*]}' 2>/dev/null)
[ -n "$MEXPR" ] || fail "no requiredDuringScheduling nodeAffinity found (a 'preferred' rule does not count — it can't guarantee placement)"
echo "$MEXPR" | grep -q 'key:tier' || fail "nodeAffinity match expression must key on 'tier' (found: $MEXPR)"
echo "$MEXPR" | grep -q 'gold'     || fail "nodeAffinity must require the value 'gold' (found: $MEXPR)"

# 2) All desired replicas are Running + Ready.
DESIRED=$(kubectl -n "$NS" get deploy pinme -o jsonpath='{.spec.replicas}' 2>/dev/null)
READY=$(kubectl -n "$NS" get deploy pinme -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
if ! [ "${READY:-0}" -ge "${DESIRED:-1}" ] 2>/dev/null; then
  fail "only ${READY:-0}/${DESIRED:-?} pods are Ready — pods pinned to a node that can't fit them will stay Pending"
fi

# 3) EVERY pod landed on the gold node.
NODES=$(kubectl -n "$NS" get pods -l app=pinme \
  -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' 2>/dev/null)
[ -n "$NODES" ] || fail "no pinme pods found"

COUNT=0
while IFS= read -r n; do
  [ -z "$n" ] && continue
  COUNT=$((COUNT + 1))
  [ "$n" = "$GOLD" ] || fail "a pod is running on '$n', not the gold node '$GOLD' — did you roll the pods after adding affinity? (kubectl -n $NS rollout restart deploy/pinme)"
done <<EOF
$NODES
EOF
[ "$COUNT" -ge "${DESIRED:-1}" ] || fail "expected ${DESIRED:-?} scheduled pods, saw $COUNT"

echo "✓ gold node                : $GOLD"
echo "✓ required nodeAffinity     : tier In [gold]"
echo "✓ pods Ready               : $READY/$DESIRED"
echo "✓ every pod on gold node    : yes ($COUNT pods)"
echo
echo "All scheduling checks passed. Submit this flag in the platform:"
echo
echo "    $FLAG"
