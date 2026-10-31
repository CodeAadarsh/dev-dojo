#!/usr/bin/env bash
# Verifier for "Drift Detective". Prints the flag only when the drift-detective
# Application has automated selfHeal enabled AND has reconciled back to Synced.
# Exit 0 = solved, 1 = not yet.
set -uo pipefail

ARGONS=argocd
APP=drift-detective
FLAG='KUBE{selfheal_reverts_the_drift}'

fail() { echo "✗ $1"; exit 1; }

kubectl get ns "$ARGONS" >/dev/null 2>&1 \
  || fail "namespace '$ARGONS' is missing — install Argo CD: bash labs/bootstrap/install-argocd.sh"

kubectl -n "$ARGONS" get application.argoproj.io "$APP" >/dev/null 2>&1 \
  || fail "Application '$APP' not found in '$ARGONS' — run setup.sh first"

SELFHEAL=$(kubectl -n "$ARGONS" get application.argoproj.io "$APP" \
  -o jsonpath='{.spec.syncPolicy.automated.selfHeal}' 2>/dev/null)
[ "$SELFHEAL" = "true" ] \
  || fail "spec.syncPolicy.automated.selfHeal must be true (found: ${SELFHEAL:-false/unset}) — enable self-heal"

SYNC=$(kubectl -n "$ARGONS" get application.argoproj.io "$APP" \
  -o jsonpath='{.status.sync.status}' 2>/dev/null)
[ "$SYNC" = "Synced" ] \
  || fail "Application '$APP' is still ${SYNC:-unknown}, not Synced — give self-heal a few seconds to revert the drift"

echo "✓ Application found           : $APP"
echo "✓ automated.selfHeal          : true"
echo "✓ sync status                 : Synced"
echo
echo "Self-heal reverted the drift — the cluster matches Git again. Submit this flag:"
echo
echo "    $FLAG"
