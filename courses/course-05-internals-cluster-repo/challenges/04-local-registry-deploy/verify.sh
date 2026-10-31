#!/usr/bin/env bash
# Verifier for "Ship From Your Own Registry". Inspects live cluster state; prints
# the flag only when a Deployment in dojo-registry pulls a localhost:5001/ image
# and is Ready. Exit 0 = solved, 1 = not yet.
set -uo pipefail

NS=dojo-registry
FLAG='KUBE{ship_from_your_own_registry}'

fail() { echo "✗ $1"; exit 1; }

kubectl get ns "$NS" >/dev/null 2>&1 || fail "namespace '$NS' is missing — run setup.sh first"

DEPLOYS=$(kubectl -n "$NS" get deploy -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
[ -n "$DEPLOYS" ] || fail "no Deployment found in '$NS' — create one that pulls a localhost:5001/ image"

# 1. Find a Deployment whose container image references the local registry.
FOUND=""
IMG=""
for d in $DEPLOYS; do
  IMGS=$(kubectl -n "$NS" get deploy "$d" -o jsonpath='{.spec.template.spec.containers[*].image}' 2>/dev/null)
  case "$IMGS" in
    *localhost:5001/*)
      FOUND="$d"
      IMG="$IMGS"
      break
      ;;
  esac
done
[ -n "$FOUND" ] || fail "no Deployment in '$NS' references a 'localhost:5001/' image — did you retag, push, and reference it?"

# 2. That Deployment must have at least one Ready replica (node actually pulled it).
READY=$(kubectl -n "$NS" get deploy "$FOUND" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
if ! [ "${READY:-0}" -ge 1 ] 2>/dev/null; then
  fail "Deployment '$FOUND' has no Ready replicas (found: ${READY:-0}) — check 'kubectl -n $NS describe pod' for ErrImagePull (push/wiring issue)"
fi

echo "✓ deployment pulling local registry : $FOUND"
echo "✓ image reference                    : $IMG"
echo "✓ Ready replicas                     : $READY (>= 1, node pulled from localhost:5001)"
echo
echo "You built, pushed, and shipped from your own registry. Submit this flag in the platform:"
echo
echo "    $FLAG"
