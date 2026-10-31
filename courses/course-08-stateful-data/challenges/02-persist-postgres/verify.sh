#!/usr/bin/env bash
# Verifier for "Persist Postgres". Checks that a postgres workload exists with
# a PVC-backed data mount and at least one ready replica.
set -uo pipefail

NS=dojo-db
FLAG='KUBE{postgres_pvc_persistence_proven}'

fail() { echo "✗ $1"; exit 1; }

kubectl get ns "$NS" >/dev/null 2>&1 || fail "namespace '$NS' missing — run setup.sh first"

# -- Find a Deployment or StatefulSet with postgres in the image --------------
DEPLOY_NAME=""
WORKLOAD_KIND=""

for kind_type in deploy statefulset; do
  candidate=$(kubectl -n "$NS" get "$kind_type" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [ -n "$candidate" ]; then
    img=$(kubectl -n "$NS" get "$kind_type" "$candidate" \
      -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null \
      | tr '[:upper:]' '[:lower:]')
    if printf '%s' "$img" | grep -q 'postgres'; then
      DEPLOY_NAME="$candidate"
      WORKLOAD_KIND="$kind_type"
      break
    fi
  fi
done

[ -n "$DEPLOY_NAME" ] || \
  fail "no Deployment or StatefulSet using a postgres image found in $NS"

IMAGE=$(kubectl -n "$NS" get "$WORKLOAD_KIND" "$DEPLOY_NAME" \
  -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)

# -- volumeMount at /var/lib/postgresql/data ----------------------------------
MOUNT_VOL_NAME=$(kubectl -n "$NS" get "$WORKLOAD_KIND" "$DEPLOY_NAME" \
  -o jsonpath='{range .spec.template.spec.containers[0].volumeMounts[*]}{.mountPath}{"\t"}{.name}{"\n"}{end}' \
  2>/dev/null \
  | awk -F'\t' '$1=="/var/lib/postgresql/data"{print $2; exit}')
[ -n "$MOUNT_VOL_NAME" ] || \
  fail "no volumeMount at /var/lib/postgresql/data in $WORKLOAD_KIND '$DEPLOY_NAME'"

# -- that volume is backed by a PVC -------------------------------------------
PVC_CLAIM=$(kubectl -n "$NS" get "$WORKLOAD_KIND" "$DEPLOY_NAME" \
  -o jsonpath='{range .spec.template.spec.volumes[*]}{.name}{"\t"}{.persistentVolumeClaim.claimName}{"\n"}{end}' \
  2>/dev/null \
  | awk -F'\t' -v vol="$MOUNT_VOL_NAME" '$1==vol && $2!="" {print $2; exit}')
[ -n "$PVC_CLAIM" ] || \
  fail "volume '$MOUNT_VOL_NAME' is not backed by a PVC (emptyDir/hostPath detected) — the data directory must use persistentVolumeClaim"

# -- PVC is Bound -------------------------------------------------------------
PHASE=$(kubectl -n "$NS" get pvc "$PVC_CLAIM" \
  -o jsonpath='{.status.phase}' 2>/dev/null)
[ "$PHASE" = "Bound" ] || \
  fail "PVC '$PVC_CLAIM' is not Bound (phase: ${PHASE:-not found}) — 'kubectl describe pvc $PVC_CLAIM -n $NS'"

# -- at least one ready replica -----------------------------------------------
READY=$(kubectl -n "$NS" get "$WORKLOAD_KIND" "$DEPLOY_NAME" \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
if ! [ "${READY:-0}" -ge 1 ] 2>/dev/null; then
  fail "no ready replicas for $WORKLOAD_KIND '$DEPLOY_NAME' (found: ${READY:-0}) — 'kubectl get pods -n $NS'"
fi

echo "✓ workload                 : $WORKLOAD_KIND/$DEPLOY_NAME"
echo "✓ image                    : $IMAGE"
echo "✓ volumeMount at data path : volume '$MOUNT_VOL_NAME' -> /var/lib/postgresql/data"
echo "✓ volume backed by PVC     : $PVC_CLAIM"
echo "✓ PVC phase                : Bound"
echo "✓ readyReplicas            : $READY"
echo
echo "All checks passed. Submit this flag:"
echo
echo "    $FLAG"
