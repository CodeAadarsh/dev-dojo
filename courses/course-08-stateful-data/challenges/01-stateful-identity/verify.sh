#!/usr/bin/env bash
# Verifier for "Stateful Identity". Inspects live cluster state and prints the
# flag only when all StatefulSet + headless Service + PVC checks pass.
set -uo pipefail

NS=dojo-sts
FLAG='KUBE{stateful_identity_headless_dns}'

fail() { echo "✗ $1"; exit 1; }

kubectl get ns "$NS" >/dev/null 2>&1 || fail "namespace '$NS' missing — run setup.sh first"

# -- StatefulSet exists -------------------------------------------------------
STS_NAME=$(kubectl -n "$NS" get statefulset \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -n "$STS_NAME" ] || fail "no StatefulSet found in $NS"

# -- volumeClaimTemplates present ---------------------------------------------
VCT_NAME=$(kubectl -n "$NS" get statefulset "$STS_NAME" \
  -o jsonpath='{.spec.volumeClaimTemplates[0].metadata.name}' 2>/dev/null)
[ -n "$VCT_NAME" ] || fail "StatefulSet '$STS_NAME' has no volumeClaimTemplates — storage must be per-pod"

# -- replicas spec >= 3 -------------------------------------------------------
REPLICAS=$(kubectl -n "$NS" get statefulset "$STS_NAME" \
  -o jsonpath='{.spec.replicas}' 2>/dev/null)
if ! [ "${REPLICAS:-0}" -ge 3 ] 2>/dev/null; then
  fail "StatefulSet '$STS_NAME' needs >= 3 replicas (found: ${REPLICAS:-none})"
fi

# -- serviceName references a headless Service --------------------------------
SVC_REF=$(kubectl -n "$NS" get statefulset "$STS_NAME" \
  -o jsonpath='{.spec.serviceName}' 2>/dev/null)
[ -n "$SVC_REF" ] || fail "StatefulSet '$STS_NAME' must set spec.serviceName"

SVC_CLUSTER_IP=$(kubectl -n "$NS" get svc "$SVC_REF" \
  -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
[ "$SVC_CLUSTER_IP" = "None" ] || \
  fail "Service '$SVC_REF' must have clusterIP: None (found: ${SVC_CLUSTER_IP:-not found})"

# -- all pods ready -----------------------------------------------------------
READY=$(kubectl -n "$NS" get statefulset "$STS_NAME" \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
if ! [ "${READY:-0}" -ge 3 ] 2>/dev/null; then
  fail "fewer than 3 pods Ready (found: ${READY:-0}) — 'kubectl get pods -n $NS'"
fi

# -- 3 Bound PVCs named <vct>-<sts>-{0,1,2} -----------------------------------
for i in 0 1 2; do
  PVC_NAME="${VCT_NAME}-${STS_NAME}-${i}"
  PHASE=$(kubectl -n "$NS" get pvc "$PVC_NAME" \
    -o jsonpath='{.status.phase}' 2>/dev/null)
  [ "$PHASE" = "Bound" ] || \
    fail "PVC '$PVC_NAME' not Bound (phase: ${PHASE:-not found}) — check 'kubectl get pvc -n $NS'"
done

echo "✓ StatefulSet              : $STS_NAME"
echo "✓ volumeClaimTemplates     : $VCT_NAME"
echo "✓ spec.serviceName         : $SVC_REF"
echo "✓ headless Service         : clusterIP=None"
echo "✓ replicas spec            : $REPLICAS"
echo "✓ readyReplicas            : $READY"
echo "✓ Bound PVCs               : ${VCT_NAME}-${STS_NAME}-0  ${VCT_NAME}-${STS_NAME}-1  ${VCT_NAME}-${STS_NAME}-2"
echo
echo "All checks passed. Submit this flag:"
echo
echo "    $FLAG"
