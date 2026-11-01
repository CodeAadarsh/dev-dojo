#!/usr/bin/env bash
# Verifier for "GitOps Handoff".
# Finds an ArgoCD Application targeting dojo-cicd-gitops, asserts automated
# sync is configured, and checks Synced + Healthy status.
set -uo pipefail

ARGONS="argocd"
TARGET_NS="dojo-cicd-gitops"
FLAG='KUBE{ci_builds_cd_syncs_gitops_handoff}'

fail() { echo "✗ $1"; exit 1; }

# ── 1. ArgoCD installed ───────────────────────────────────────────────────────
kubectl get ns "$ARGONS" >/dev/null 2>&1 \
  || fail "namespace '$ARGONS' is missing — install ArgoCD: bash labs/bootstrap/install-argocd.sh"

kubectl get crd applications.argoproj.io >/dev/null 2>&1 \
  || fail "ArgoCD CRD 'applications.argoproj.io' not found — is ArgoCD fully installed?"

# ── 2. Find an Application targeting dojo-cicd-gitops ────────────────────────
APPS=$(kubectl -n "$ARGONS" get applications.argoproj.io \
  -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
[ -n "$APPS" ] \
  || fail "no ArgoCD Applications found in '$ARGONS' — apply your application.yaml: kubectl apply -f ~/.kube-dojo-work/06-gitops-handoff/application.yaml -n argocd"

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
  || fail "no Application has spec.destination.namespace == '$TARGET_NS' (checked: $APPS) — set the destination namespace to '$TARGET_NS' in application.yaml"

# ── 3. Automated sync is configured ──────────────────────────────────────────
AUTO_SYNC=$(kubectl -n "$ARGONS" get application.argoproj.io "$MATCH" \
  -o jsonpath='{.spec.syncPolicy.automated}' 2>/dev/null)
[ -n "$AUTO_SYNC" ] \
  || fail "Application '$MATCH' does not have spec.syncPolicy.automated — add 'automated: {}' under syncPolicy; without it ArgoCD only detects drift but won't self-heal"

# ── 4. Sync status ────────────────────────────────────────────────────────────
SYNC=$(kubectl -n "$ARGONS" get application.argoproj.io "$MATCH" \
  -o jsonpath='{.status.sync.status}' 2>/dev/null)
[ "$SYNC" = "Synced" ] \
  || fail "Application '$MATCH' is not Synced (found: ${SYNC:-unknown}) — trigger a sync and wait: kubectl -n argocd get application $MATCH -w"

# ── 5. Health status ──────────────────────────────────────────────────────────
HEALTH=$(kubectl -n "$ARGONS" get application.argoproj.io "$MATCH" \
  -o jsonpath='{.status.health.status}' 2>/dev/null)
[ "$HEALTH" = "Healthy" ] \
  || fail "Application '$MATCH' is not Healthy (found: ${HEALTH:-unknown}) — check deployed pods in '$TARGET_NS': kubectl get pods -n $TARGET_NS"

REPO=$(kubectl -n "$ARGONS" get application.argoproj.io "$MATCH" \
  -o jsonpath='{.spec.source.repoURL}' 2>/dev/null)

echo "✓ ArgoCD present"
echo "✓ Application found               : $MATCH"
echo "✓ destination namespace           : $TARGET_NS"
echo "✓ automated sync configured       : yes"
echo "✓ sync status                     : Synced"
echo "✓ health status                   : Healthy"
echo "✓ tracking                        : $REPO"
echo
echo "CI builds. CD syncs. The handoff is a git push."
echo
echo "Submit this flag:"
echo
echo "    $FLAG"
