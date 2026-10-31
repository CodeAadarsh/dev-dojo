#!/usr/bin/env bash
# Verifier for "Kustomize Overlay for Production".
# Checks: Deployment 'web' in dojo-kustomize has 3 replicas and label env=prod.
set -uo pipefail

NS=dojo-kustomize
DEPLOY=web
FLAG='KUBE{kustomize_overlay_patches_prod}'

fail() { echo "✗ $1"; exit 1; }

kubectl get ns "$NS" >/dev/null 2>&1 || fail "namespace '$NS' not found — run setup.sh first"

kubectl -n "$NS" get deploy "$DEPLOY" >/dev/null 2>&1 \
  || fail "Deployment '$DEPLOY' not found in $NS — did you run 'kubectl apply -k overlays/prod/'?"

REPLICAS=$(kubectl -n "$NS" get deploy "$DEPLOY" \
  -o jsonpath='{.spec.replicas}' 2>/dev/null)
[ "$REPLICAS" = "3" ] \
  || fail "Deployment '$DEPLOY' needs spec.replicas=3 (found: ${REPLICAS:-unset}) — check your replica-patch.yaml"

ENV_LABEL=$(kubectl -n "$NS" get deploy "$DEPLOY" \
  -o jsonpath='{.metadata.labels.env}' 2>/dev/null)
[ "$ENV_LABEL" = "prod" ] \
  || fail "Deployment '$DEPLOY' missing label env=prod (found: ${ENV_LABEL:-<unset>}) — check commonLabels in your overlay kustomization.yaml"

READY=$(kubectl -n "$NS" get deploy "$DEPLOY" \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
if ! [ "${READY:-0}" -ge 3 ] 2>/dev/null; then
  fail "fewer than 3 pods are Ready (found: ${READY:-0}) — wait for rollout to complete"
fi

echo "✓ Deployment             : $DEPLOY"
echo "✓ spec.replicas          : $REPLICAS"
echo "✓ label env              : $ENV_LABEL"
echo "✓ ready replicas         : $READY"
echo
echo "All checks passed. Submit this flag in the platform:"
echo
echo "    $FLAG"
