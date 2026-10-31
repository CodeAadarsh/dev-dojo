#!/usr/bin/env bash
# Verifier for "Logical Backup Job".
# Inspects live cluster state; prints the flag only when both checks pass.
# Exit 0 = solved, 1 = not yet.
set -uo pipefail

NS=dojo-backup
FLAG='KUBE{backup_job_to_pvc_succeeded}'

fail() { echo "✗ $1"; exit 1; }

kubectl get ns "$NS" >/dev/null 2>&1 || fail "namespace '$NS' is missing — run setup.sh first"

# ── Check 1: a Job exists and has succeeded ──────────────────────────────────
JOB_NAME=$(kubectl -n "$NS" get jobs -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -n "$JOB_NAME" ] || fail "no Job found in namespace '$NS' — create one that writes to the backup PVC"

SUCCEEDED=$(kubectl -n "$NS" get job "$JOB_NAME" -o jsonpath='{.status.succeeded}' 2>/dev/null)
if ! [ "${SUCCEEDED:-0}" -ge 1 ] 2>/dev/null; then
  ACTIVE=$(kubectl -n "$NS" get job "$JOB_NAME" -o jsonpath='{.status.active}' 2>/dev/null)
  FAILED=$(kubectl -n "$NS" get job "$JOB_NAME" -o jsonpath='{.status.failed}' 2>/dev/null)
  fail "Job '$JOB_NAME' has not succeeded yet (succeeded=${SUCCEEDED:-0}, active=${ACTIVE:-0}, failed=${FAILED:-0})"
fi

# ── Check 2: a PVC exists and is Bound ───────────────────────────────────────
PVC_NAME=$(kubectl -n "$NS" get pvc -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -n "$PVC_NAME" ] || fail "no PersistentVolumeClaim found in namespace '$NS' — create a PVC for the backup"

PVC_PHASE=$(kubectl -n "$NS" get pvc "$PVC_NAME" -o jsonpath='{.status.phase}' 2>/dev/null)
[ "$PVC_PHASE" = "Bound" ] || fail "PVC '$PVC_NAME' is not Bound (phase: ${PVC_PHASE:-Pending}) — is a StorageClass provisioner available?"

echo "✓ Job succeeded          : $JOB_NAME (status.succeeded=${SUCCEEDED})"
echo "✓ Backup PVC Bound       : $PVC_NAME"
echo
echo "Backup job verified — artifact is on durable storage. Submit this flag in the platform:"
echo
echo "    $FLAG"
