#!/usr/bin/env bash
# Verifier: the 'viewer' SA in dojo-rbac-exam can get/list pods but not delete.
set -uo pipefail

NS=dojo-rbac-exam
FLAG='KUBE{viewer_lists_but_cannot_delete}'
fail() { echo "✗ $1"; exit 1; }

kubectl get ns "$NS" >/dev/null 2>&1 || fail "namespace '$NS' missing — run setup.sh"
kubectl -n "$NS" get sa viewer >/dev/null 2>&1 || fail "ServiceAccount 'viewer' not found in $NS"

SUB="system:serviceaccount:$NS:viewer"
CANLIST=$(kubectl auth can-i list   pods --as="$SUB" -n "$NS" 2>/dev/null)
CANGET=$(kubectl auth can-i  get    pods --as="$SUB" -n "$NS" 2>/dev/null)
CANDEL=$(kubectl auth can-i  delete pods --as="$SUB" -n "$NS" 2>/dev/null)

[ "$CANGET" = "yes" ]  || fail "viewer must be able to GET pods (got: ${CANGET:-no})"
[ "$CANLIST" = "yes" ] || fail "viewer must be able to LIST pods (got: ${CANLIST:-no})"
[ "$CANDEL" = "no" ]   || fail "viewer must NOT be able to DELETE pods (got: ${CANDEL:-yes}) — Role is too broad"

echo "✓ viewer: get=yes list=yes delete=no"
echo
echo "Submit this flag:"
echo
echo "    $FLAG"
