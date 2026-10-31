#!/usr/bin/env bash
# Verifier for "Custom Resource API — Environment".
# Checks: CRD environments.platform.dojo is Established AND an Environment CR
# exists in dojo-crd2 with a valid spec.tier (dev/stage/prod).
set -uo pipefail

NS=dojo-crd2
CRD_NAME=environments.platform.dojo
FLAG='KUBE{crd_environment_api_established}'

fail() { echo "✗ $1"; exit 1; }

# ── CRD presence ───────────────────────────────────────────────────────────────
kubectl get crd "$CRD_NAME" >/dev/null 2>&1 \
  || fail "CRD '$CRD_NAME' not found — define and apply it first"

# ── CRD Established ────────────────────────────────────────────────────────────
ESTABLISHED=$(kubectl get crd "$CRD_NAME" \
  -o jsonpath='{.status.conditions[?(@.type=="Established")].status}' 2>/dev/null)
[ "$ESTABLISHED" = "True" ] \
  || fail "CRD '$CRD_NAME' is not Established (status: ${ESTABLISHED:-unknown}) — wait a few seconds and retry"

# ── Namespace ──────────────────────────────────────────────────────────────────
kubectl get ns "$NS" >/dev/null 2>&1 \
  || fail "namespace '$NS' not found — run setup.sh first"

# ── Environment CR exists ──────────────────────────────────────────────────────
CR_NAME=$(kubectl -n "$NS" get "$CRD_NAME" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -n "$CR_NAME" ] \
  || fail "no Environment CR found in namespace '$NS' — create one with a valid spec.tier"

# ── spec.tier is valid ─────────────────────────────────────────────────────────
TIER=$(kubectl -n "$NS" get "$CRD_NAME" "$CR_NAME" \
  -o jsonpath='{.spec.tier}' 2>/dev/null)
case "$TIER" in
  dev|stage|prod) ;;
  *) fail "Environment CR '$CR_NAME' has spec.tier='${TIER:-unset}' — must be dev, stage, or prod" ;;
esac

echo "✓ CRD              : $CRD_NAME (Established)"
echo "✓ Namespace        : $NS"
echo "✓ Environment CR   : $CR_NAME (spec.tier=$TIER)"
echo
echo "All CRD checks passed. Submit this flag in the platform:"
echo
echo "    $FLAG"
