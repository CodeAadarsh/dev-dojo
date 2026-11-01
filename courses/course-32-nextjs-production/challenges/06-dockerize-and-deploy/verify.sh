#!/usr/bin/env bash
# Verifier for "Dockerize and Deploy".
# Checks that the dojo-nextjs namespace has a Deployment named 'nextjs'
# with readyReplicas >= 1 running the dojo-nextjs:v1 image.
set -uo pipefail

FLAG='KUBE{nextjs_runs_in_kubernetes}'
NS="dojo-nextjs"
DEPLOY="nextjs"
EXPECTED_IMAGE="dojo-nextjs:v1"

fail() { echo "✗ $1"; exit 1; }

# ── prereq check ──────────────────────────────────────────────────────────────
command -v kubectl >/dev/null 2>&1 || fail "kubectl not found"

CTX="$(kubectl config current-context 2>/dev/null || true)"
if [ "$CTX" != "kind-dojo" ]; then
  echo "WARNING: current context is '${CTX:-<none>}', expected 'kind-dojo'."
  echo "         Continuing — if checks fail, run: kubectl config use-context kind-dojo"
fi

# ── check namespace ───────────────────────────────────────────────────────────
kubectl get namespace "$NS" >/dev/null 2>&1 || \
  fail "namespace '$NS' not found — create it and deploy the app"

# ── check deployment exists ───────────────────────────────────────────────────
kubectl -n "$NS" get deployment "$DEPLOY" >/dev/null 2>&1 || \
  fail "Deployment '$DEPLOY' not found in namespace '$NS'"

# ── check readyReplicas >= 1 ──────────────────────────────────────────────────
READY="$(kubectl -n "$NS" get deployment "$DEPLOY" \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo '0')"
READY="${READY:-0}"
[ "$READY" -ge 1 ] 2>/dev/null || \
  fail "Deployment '$DEPLOY' readyReplicas=$READY (need >= 1) — check pod logs: kubectl -n $NS logs -l app=$DEPLOY"

# ── check image ───────────────────────────────────────────────────────────────
IMAGE="$(kubectl -n "$NS" get deployment "$DEPLOY" \
  -o jsonpath='{.spec.template.spec.containers[0].image}')"
[ "$IMAGE" = "$EXPECTED_IMAGE" ] || \
  fail "Deployment image is '$IMAGE', expected '$EXPECTED_IMAGE'"

echo "✓ namespace $NS exists"
echo "✓ Deployment $DEPLOY readyReplicas=$READY"
echo "✓ Image is $IMAGE"
echo
echo "All checks passed. Submit this flag in the platform:"
echo
echo "    $FLAG"
