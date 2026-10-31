#!/usr/bin/env bash
# Verifier for "GitOps or It Didn't Happen". Walks every Argo CD Application in
# the argocd namespace and prints the flag only when one of them targets
# dojo-gitops AND is Synced AND is Healthy. Exit 0 = solved, 1 = not yet.
set -uo pipefail

ARGONS=argocd
TARGET_NS=dojo-gitops
FLAG='KUBE{gitops_or_it_didnt_happen}'

fail() { echo "✗ $1"; exit 1; }

kubectl get ns "$ARGONS" >/dev/null 2>&1 \
  || fail "namespace '$ARGONS' is missing — install Argo CD: bash labs/bootstrap/install-argocd.sh"

kubectl get crd applications.argoproj.io >/dev/null 2>&1 \
  || fail "Argo CD CRD 'applications.argoproj.io' not found — is Argo CD installed?"

APPS=$(kubectl -n "$ARGONS" get applications.argoproj.io -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
[ -n "$APPS" ] || fail "no Argo CD Applications found in '$ARGONS' — create one targeting '$TARGET_NS'"

MATCH=""
for app in $APPS; do
  DEST=$(kubectl -n "$ARGONS" get application.argoproj.io "$app" \
    -o jsonpath='{.spec.destination.namespace}' 2>/dev/null)
  if [ "$DEST" = "$TARGET_NS" ]; then
    MATCH="$app"
    break
  fi
done

[ -n "$MATCH" ] \
  || fail "no Application has spec.destination.namespace == '$TARGET_NS' (checked: $APPS)"

SYNC=$(kubectl -n "$ARGONS" get application.argoproj.io "$MATCH" \
  -o jsonpath='{.status.sync.status}' 2>/dev/null)
[ "$SYNC" = "Synced" ] \
  || fail "Application '$MATCH' is not Synced (found: ${SYNC:-unknown}) — trigger a sync and wait for it to converge"

HEALTH=$(kubectl -n "$ARGONS" get application.argoproj.io "$MATCH" \
  -o jsonpath='{.status.health.status}' 2>/dev/null)
[ "$HEALTH" = "Healthy" ] \
  || fail "Application '$MATCH' is not Healthy (found: ${HEALTH:-unknown}) — check the deployed pods in '$TARGET_NS'"

echo "✓ Application found           : $MATCH"
echo "✓ destination namespace       : $TARGET_NS"
echo "✓ sync status                 : Synced"
echo "✓ health status               : Healthy"
echo
echo "The cluster converged to Git. Submit this flag in the platform:"
echo
echo "    $FLAG"
