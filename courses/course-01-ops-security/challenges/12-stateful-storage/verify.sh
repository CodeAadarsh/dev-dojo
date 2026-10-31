#!/usr/bin/env bash
# Verifier for "State That Survives". Confirms in dojo-storage:
#   (1) a StatefulSet whose spec defines volumeClaimTemplates;
#   (2) at least one PersistentVolumeClaim in phase Bound;
#   (3) the StatefulSet reports readyReplicas >= 1.
# Prints the flag only when all hold. Exit 0 = solved, 1 = not yet.
# Uses only kubectl + POSIX tools (no jq).
set -uo pipefail

NS=dojo-storage
FLAG='KUBE{volumeclaimtemplates_outlive_the_pod}'

fail() { echo "✗ $1"; exit 1; }

kubectl get ns "$NS" >/dev/null 2>&1 || fail "namespace '$NS' is missing — run setup.sh first"

STSS=$(kubectl -n "$NS" get statefulset -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
[ -n "$STSS" ] || fail "no StatefulSet in $NS — convert the 'notes' Deployment to a StatefulSet with volumeClaimTemplates"

STS=""
VCT_NAME=""
for s in $STSS; do
  VCT=$(kubectl -n "$NS" get statefulset "$s" -o jsonpath='{.spec.volumeClaimTemplates[*].metadata.name}' 2>/dev/null)
  if [ -n "$VCT" ]; then
    STS="$s"
    VCT_NAME="$VCT"
    break
  fi
done
[ -n "$STS" ] || fail "a StatefulSet exists but none define volumeClaimTemplates — an emptyDir StatefulSet does not count"

READY=$(kubectl -n "$NS" get statefulset "$STS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
if ! [ "${READY:-0}" -ge 1 ] 2>/dev/null; then
  fail "StatefulSet '$STS' has no ready replicas (found: ${READY:-0}) — is the pod Running and its PVC Bound?"
fi

PVCS=$(kubectl -n "$NS" get pvc -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
[ -n "$PVCS" ] || fail "no PersistentVolumeClaim in $NS — the volumeClaimTemplate should provision one per replica"

BOUND=""
for pvc in $PVCS; do
  PHASE=$(kubectl -n "$NS" get pvc "$pvc" -o jsonpath='{.status.phase}' 2>/dev/null)
  if [ "$PHASE" = "Bound" ]; then
    BOUND="$pvc"
    break
  fi
done
[ -n "$BOUND" ] || fail "no PVC is Bound in $NS — check StorageClass (kind ships 'standard') and that a PV was provisioned"

CAP=$(kubectl -n "$NS" get pvc "$BOUND" -o jsonpath='{.status.capacity.storage}' 2>/dev/null)
SC=$(kubectl -n "$NS" get pvc "$BOUND" -o jsonpath='{.spec.storageClassName}' 2>/dev/null)

echo "✓ StatefulSet               : $STS"
echo "✓ volumeClaimTemplate       : $VCT_NAME"
echo "✓ ready replicas            : $READY"
echo "✓ bound PVC                 : $BOUND (${CAP:-?}, storageClass=${SC:-default})"
echo
echo "State now lives on a PersistentVolume that outlives any single pod."
echo "Submit this flag in the platform:"
echo
echo "    $FLAG"
