#!/usr/bin/env bash
# Verifier for "Dependency Failure: Graceful Degradation".
# Injects the fault (scales backend to 0), waits for probe cycles to complete,
# then asserts the app Deployment still has readyReplicas >= 1.
# Restores backend on exit regardless of outcome.
set -uo pipefail

NS=dojo-chaos-dep
FLAG='KUBE{graceful_degradation_keeps_pods_ready}'

fail() { echo "✗ $1"; exit 1; }

# ── restore backend on exit (success or failure) ─────────────────────────
_ORIGINAL_BACKEND_REPLICAS=2
cleanup() {
    kubectl -n "$NS" scale deploy/backend --replicas="$_ORIGINAL_BACKEND_REPLICAS" \
        >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ── pre-flight ────────────────────────────────────────────────────────────
kubectl get ns "$NS" >/dev/null 2>&1 \
    || fail "namespace '$NS' not found — run setup.sh first"

kubectl -n "$NS" get deploy backend >/dev/null 2>&1 \
    || fail "Deployment 'backend' not found in $NS — run setup.sh first"

kubectl -n "$NS" get deploy app >/dev/null 2>&1 \
    || fail "Deployment 'app' not found in $NS — run setup.sh first"

# Save current backend replica count for restore
_ORIGINAL_BACKEND_REPLICAS=$(kubectl -n "$NS" get deploy backend \
    -o jsonpath='{.spec.replicas}' 2>/dev/null)
_ORIGINAL_BACKEND_REPLICAS="${_ORIGINAL_BACKEND_REPLICAS:-2}"

# ── check resource requests on app ────────────────────────────────────────
APP_REQ=$(kubectl -n "$NS" get deploy app \
    -o jsonpath='{.spec.template.spec.containers[0].resources.requests}' 2>/dev/null)
[ -n "$APP_REQ" ] \
    || fail "app container is missing resource requests — add cpu + memory requests"

# ── inject fault: scale backend to 0 ─────────────────────────────────────
echo "Injecting fault: scaling backend to 0 replicas..."
kubectl -n "$NS" scale deploy/backend --replicas=0 >/dev/null

echo "Waiting 25s for readiness probes to cycle (failureThreshold × periodSeconds)..."
sleep 25

# ── assert backend is at 0 ────────────────────────────────────────────────
BACKEND_READY=$(kubectl -n "$NS" get deploy backend \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
if [ "${BACKEND_READY:-0}" -ne 0 ] 2>/dev/null; then
    fail "backend still has ready replicas after scale-to-0 (found: ${BACKEND_READY}) — cluster state unexpected"
fi

# ── assert app is still ready ─────────────────────────────────────────────
APP_READY=$(kubectl -n "$NS" get deploy app \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
if ! [ "${APP_READY:-0}" -ge 1 ] 2>/dev/null; then
    fail "app has 0 ready replicas with backend down (found: ${APP_READY:-0}) — the probe is still coupled to backend-svc; decouple it to check the app's own health"
fi

APP_REPLICAS=$(kubectl -n "$NS" get deploy app \
    -o jsonpath='{.spec.replicas}' 2>/dev/null)

echo
echo "✓ fault injected           : backend readyReplicas = 0"
echo "✓ app still serving        : readyReplicas = $APP_READY / $APP_REPLICAS"
echo "✓ resource requests set    : yes"
echo "✓ backend restoring        : will scale back to $_ORIGINAL_BACKEND_REPLICAS on exit"
echo
echo "Graceful degradation confirmed. Submit this flag in the platform:"
echo
echo "    $FLAG"
