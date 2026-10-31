#!/usr/bin/env bash
# Verifier for "Expand a Volume". Checks that PVC dojo-data in dojo-resize
# has spec.resources.requests.storage >= 2Gi.
set -uo pipefail

NS=dojo-resize
PVC_NAME=dojo-data
FLAG='KUBE{volume_expansion_unlocked}'

fail() { echo "✗ $1"; exit 1; }

kubectl get ns "$NS" >/dev/null 2>&1 || fail "namespace '$NS' missing — run setup.sh first"

# -- PVC must be present and Bound --------------------------------------------
PHASE=$(kubectl -n "$NS" get pvc "$PVC_NAME" \
  -o jsonpath='{.status.phase}' 2>/dev/null)
[ "$PHASE" = "Bound" ] || \
  fail "PVC '$PVC_NAME' is not Bound (phase: ${PHASE:-not found}) — run setup.sh and wait for the pod to start"

# -- spec.resources.requests.storage >= 2Gi -----------------------------------
SPEC_STORAGE=$(kubectl -n "$NS" get pvc "$PVC_NAME" \
  -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null)
[ -n "$SPEC_STORAGE" ] || fail "PVC '$PVC_NAME' has no storage request"

# Accept NNGi format only; guide learner to use Gi units
STORAGE_GI=$(printf '%s' "$SPEC_STORAGE" | sed -n 's/^\([0-9][0-9]*\)Gi$/\1/p')
[ -n "$STORAGE_GI" ] || \
  fail "PVC storage '$SPEC_STORAGE' is not in Gi format — patch to e.g. '2Gi'"
if [ "$STORAGE_GI" -lt 2 ]; then
  fail "PVC '$PVC_NAME' spec.resources.requests.storage must be >= 2Gi (found: $SPEC_STORAGE)"
fi

# -- Report status (informational) --------------------------------------------
STATUS_CAP=$(kubectl -n "$NS" get pvc "$PVC_NAME" \
  -o jsonpath='{.status.capacity.storage}' 2>/dev/null || echo "unknown")
CONDITION=$(kubectl -n "$NS" get pvc "$PVC_NAME" \
  -o jsonpath='{.status.conditions[*].type}' 2>/dev/null || echo "none")

echo "✓ PVC                      : $PVC_NAME"
echo "✓ phase                    : Bound"
echo "✓ spec.resources.requests  : $SPEC_STORAGE (>= 2Gi)"
echo "  status.capacity.storage  : ${STATUS_CAP} (local-path may not reflect resize)"
echo "  resize conditions        : ${CONDITION:-none}"
echo
echo "All checks passed. Submit this flag:"
echo
echo "    $FLAG"
