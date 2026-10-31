#!/usr/bin/env bash
# Verifier for "StorageClass: Retain Your Data".
# Navigates PVC -> StorageClass and checks the reclaim policy and expansion flag.
# Exit 0 = solved, 1 = not yet.
set -uo pipefail

NS=dojo-sc
FLAG='KUBE{retain_policy_survives_pvc_delete}'

fail() { echo "✗ $1"; exit 1; }

kubectl get ns "$NS" >/dev/null 2>&1 || fail "namespace '$NS' is missing — run setup.sh first"

# ── Check 1: a PVC exists and is Bound ───────────────────────────────────────
PVC_NAME=$(kubectl -n "$NS" get pvc -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -n "$PVC_NAME" ] || fail "no PersistentVolumeClaim found in namespace '$NS'"

PVC_PHASE=$(kubectl -n "$NS" get pvc "$PVC_NAME" -o jsonpath='{.status.phase}' 2>/dev/null)
[ "$PVC_PHASE" = "Bound" ] || fail "PVC '$PVC_NAME' is not Bound (phase: ${PVC_PHASE:-Pending})"

# ── Check 2: that PVC references a StorageClass ───────────────────────────────
SC_NAME=$(kubectl -n "$NS" get pvc "$PVC_NAME" -o jsonpath='{.spec.storageClassName}' 2>/dev/null)
[ -n "$SC_NAME" ] || fail "PVC '$PVC_NAME' has no storageClassName — set spec.storageClassName explicitly"

kubectl get storageclass "$SC_NAME" >/dev/null 2>&1 || fail "StorageClass '$SC_NAME' not found — did you create it?"

# ── Check 3: reclaimPolicy is Retain ─────────────────────────────────────────
RECLAIM=$(kubectl get storageclass "$SC_NAME" -o jsonpath='{.reclaimPolicy}' 2>/dev/null)
[ "$RECLAIM" = "Retain" ] || fail "StorageClass '$SC_NAME' reclaimPolicy is '$RECLAIM', expected 'Retain'"

# ── Check 4: allowVolumeExpansion is true ─────────────────────────────────────
EXPAND=$(kubectl get storageclass "$SC_NAME" -o jsonpath='{.allowVolumeExpansion}' 2>/dev/null)
[ "$EXPAND" = "true" ] || fail "StorageClass '$SC_NAME' does not set allowVolumeExpansion: true (found: ${EXPAND:-unset})"

echo "✓ PVC Bound              : $PVC_NAME"
echo "✓ StorageClass           : $SC_NAME"
echo "✓ reclaimPolicy          : $RECLAIM"
echo "✓ allowVolumeExpansion   : $EXPAND"
echo
echo "Retain policy confirmed — data survives PVC deletion. Submit this flag in the platform:"
echo
echo "    $FLAG"
