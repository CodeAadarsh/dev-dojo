#!/usr/bin/env bash
# Verifier for "ApplicationSet — Multi-Env GitOps".
# Checks: ArgoCD installed, ApplicationSet exists in argocd namespace,
# has >=1 generator, and template destination.namespace is dojo-appset.
set -uo pipefail

NS_ARGO=argocd
FLAG='KUBE{applicationset_gitops_multienv}'

fail() { echo "✗ $1"; exit 1; }

# ── ArgoCD presence ────────────────────────────────────────────────────────────
kubectl get ns "$NS_ARGO" >/dev/null 2>&1 \
  || fail "namespace 'argocd' not found — install ArgoCD: bash labs/bootstrap/install-argocd.sh"

kubectl get crd applicationsets.argoproj.io >/dev/null 2>&1 \
  || fail "ApplicationSet CRD not found — ArgoCD with ApplicationSet controller is required"

# ── ApplicationSet exists ──────────────────────────────────────────────────────
APPSET_NAME=$(kubectl -n "$NS_ARGO" get applicationset \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -n "$APPSET_NAME" ] \
  || fail "no ApplicationSet found in namespace 'argocd' — create one targeting dojo-appset"

# ── Has at least one generator ─────────────────────────────────────────────────
GEN0=$(kubectl -n "$NS_ARGO" get applicationset "$APPSET_NAME" \
  -o jsonpath='{.spec.generators[0]}' 2>/dev/null)
[ -n "$GEN0" ] \
  || fail "ApplicationSet '$APPSET_NAME' has no spec.generators — add at least one list generator"

# ── Template destination namespace is dojo-appset ─────────────────────────────
DEST_NS=$(kubectl -n "$NS_ARGO" get applicationset "$APPSET_NAME" \
  -o jsonpath='{.spec.template.spec.destination.namespace}' 2>/dev/null)
[ "$DEST_NS" = "dojo-appset" ] \
  || fail "ApplicationSet template must have destination.namespace 'dojo-appset' (found: ${DEST_NS:-unset})"

# ── Count generators ───────────────────────────────────────────────────────────
GEN_COUNT=$(kubectl -n "$NS_ARGO" get applicationset "$APPSET_NAME" \
  -o jsonpath='{range .spec.generators[*]}{.}{"\n"}{end}' 2>/dev/null | grep -c '{' || true)

echo "✓ ArgoCD namespace        : $NS_ARGO"
echo "✓ ApplicationSet          : $APPSET_NAME"
echo "✓ generators present      : yes (>= 1)"
echo "✓ destination namespace   : $DEST_NS"
echo
echo "All ApplicationSet checks passed. Submit this flag in the platform:"
echo
echo "    $FLAG"
