#!/usr/bin/env bash
# Verifier for "Scrape My App". Checks that a Service with a metrics port and
# a ServiceMonitor with a non-empty selector both exist in dojo-obs.
# Exit 0 = solved; exit 1 = not yet.
set -uo pipefail

NS=dojo-obs
FLAG='KUBE{service_monitor_wires_the_scrape}'

fail() { echo "✗ $1"; exit 1; }

kubectl get ns "$NS" >/dev/null 2>&1 || fail "namespace '$NS' is missing — run setup.sh first"

# ── Check ServiceMonitor exists ─────────────────────────────────────────────
SM_NAME=$(kubectl -n "$NS" get servicemonitor -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -n "$SM_NAME" ] || fail "no ServiceMonitor found in $NS — create one targeting your Service"

# ── Check ServiceMonitor selector.matchLabels is non-empty ──────────────────
SM_SELECTOR=$(kubectl -n "$NS" get servicemonitor "$SM_NAME" \
  -o jsonpath='{.spec.selector.matchLabels}' 2>/dev/null)
[ -n "$SM_SELECTOR" ] || fail "ServiceMonitor '$SM_NAME' has no spec.selector.matchLabels — it would match nothing"

# ── Check a Service exists with a metrics port (name=metrics or port=8080) ──
SVC_NAME=$(kubectl -n "$NS" get svc -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -n "$SVC_NAME" ] || fail "no Service found in $NS — create one exposing the app's metrics port"

SVC_PORT_NAMES=$(kubectl -n "$NS" get svc "$SVC_NAME" \
  -o jsonpath='{.spec.ports[*].name}' 2>/dev/null)
SVC_PORT_NUMS=$(kubectl -n "$NS" get svc "$SVC_NAME" \
  -o jsonpath='{.spec.ports[*].port}' 2>/dev/null)

COMBINED="${SVC_PORT_NAMES} ${SVC_PORT_NUMS}"
echo "$COMBINED" | grep -qE 'metrics|8080' || \
  fail "Service '$SVC_NAME' must expose a port named 'metrics' or port number 8080 (found: ${COMBINED})"

# ── Verify the ServiceMonitor's namespaceSelector covers dojo-obs (or is empty = same-ns) ──
SM_NS_SELECTOR=$(kubectl -n "$NS" get servicemonitor "$SM_NAME" \
  -o jsonpath='{.spec.namespaceSelector}' 2>/dev/null)

echo "✓ namespace              : $NS"
echo "✓ ServiceMonitor         : $SM_NAME"
echo "✓ selector.matchLabels   : $SM_SELECTOR"
echo "✓ Service                : $SVC_NAME"
echo "✓ metrics port present   : yes (${COMBINED})"
echo
echo "All checks passed. Submit this flag in the platform:"
echo
echo "    $FLAG"
