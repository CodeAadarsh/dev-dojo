#!/usr/bin/env bash
# Verifier for "ConfigMap Gone Wrong". Confirms the ConfigMap exposes the page
# under key 'index.html' AND that nginx actually serves the marker. Prints the
# flag only when both pass. Exit 0 = solved, 1 = not yet.
set -uo pipefail

NS=dojo-config
MARKER='DOJO_CONFIG_OK'
FLAG='KUBE{configmap_key_must_match_the_mount}'

fail() { echo "✗ $1"; exit 1; }

kubectl get ns "$NS" >/dev/null 2>&1 || fail "namespace '$NS' is missing — run setup.sh first"
kubectl -n "$NS" get configmap web-content >/dev/null 2>&1 || fail "ConfigMap 'web-content' not found in $NS"
kubectl -n "$NS" get deploy web >/dev/null 2>&1 || fail "Deployment 'web' not found in $NS"

INDEX=$(kubectl -n "$NS" get configmap web-content -o jsonpath='{.data.index\.html}' 2>/dev/null)
[ -n "$INDEX" ] || fail "ConfigMap 'web-content' needs a key 'index.html' (that is the filename nginx serves)"
case "$INDEX" in
  *"$MARKER"*) ;;
  *) fail "the 'index.html' key does not contain the expected marker '$MARKER'" ;;
esac

READY=$(kubectl -n "$NS" get deploy web -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
if ! [ "${READY:-0}" -ge 1 ] 2>/dev/null; then
  fail "no Ready pods for Deployment 'web' (found: ${READY:-0}) — wait for the rollout"
fi

BODY=$(kubectl -n "$NS" exec deploy/web -- wget -qO- localhost 2>/dev/null)
case "$BODY" in
  *"$MARKER"*) ;;
  *) fail "nginx did not serve the marker '$MARKER' — the page is still mis-wired (got a 403 or wrong content)" ;;
esac

echo "✓ ConfigMap 'web-content'  : present"
echo "✓ key 'index.html'         : present, contains marker"
echo "✓ pod serves marker        : '$MARKER' found over HTTP"
echo
echo "Config is wired correctly. Submit this flag in the platform:"
echo
echo "    $FLAG"
