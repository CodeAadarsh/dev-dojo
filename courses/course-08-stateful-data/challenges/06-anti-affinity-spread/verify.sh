#!/usr/bin/env bash
# Verifier for "Anti-Affinity Spread for StatefulSets".
# Checks: (1) podAntiAffinity is configured on the StatefulSet,
#         (2) pods are running on more than one distinct node.
# Exit 0 = solved, 1 = not yet.
set -uo pipefail

NS=dojo-spread
STS=cache
FLAG='KUBE{anti_affinity_spreads_pods_across_nodes}'

fail() { echo "✗ $1"; exit 1; }

kubectl get ns "$NS" >/dev/null 2>&1 || fail "namespace '$NS' is missing — run setup.sh first"
kubectl -n "$NS" get sts "$STS" >/dev/null 2>&1 || fail "StatefulSet '$STS' not found in '$NS' — run setup.sh first"

# ── Check 1: podAntiAffinity is configured ────────────────────────────────────
ANTI=$(kubectl -n "$NS" get sts "$STS" \
  -o jsonpath='{.spec.template.spec.affinity.podAntiAffinity}' 2>/dev/null)
[ -n "$ANTI" ] || fail "StatefulSet '$STS' has no podAntiAffinity — add it to spec.template.spec.affinity.podAntiAffinity"

# ── Check 2: pods are Running ─────────────────────────────────────────────────
RUNNING=$(kubectl -n "$NS" get pods -l app=cache \
  -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null \
  | grep -c '^Running$' || true)
if ! [ "${RUNNING:-0}" -ge 2 ] 2>/dev/null; then
  fail "fewer than 2 pods are Running in '$NS' (found: ${RUNNING:-0}) — wait for pods to reschedule"
fi

# ── Check 3: pods are on more than one node ───────────────────────────────────
NODES=$(kubectl -n "$NS" get pods -l app=cache \
  -o jsonpath='{.items[*].spec.nodeName}' 2>/dev/null)
UNIQUE=$(printf '%s' "$NODES" | tr ' ' '\n' | sort -u | grep -c .)
if ! [ "${UNIQUE:-0}" -ge 2 ] 2>/dev/null; then
  fail "all pods are on the same node (unique nodes: ${UNIQUE:-0}) — podAntiAffinity is not spreading pods yet; try deleting the pods to force rescheduling: kubectl -n $NS delete pods -l app=cache"
fi

echo "✓ podAntiAffinity set    : yes"
echo "✓ Running pods           : $RUNNING"
echo "✓ Distinct nodes         : $UNIQUE"
echo
echo "Pods are spread across $UNIQUE nodes — single-node failure cannot take down the cache. Submit this flag:"
echo
echo "    $FLAG"
