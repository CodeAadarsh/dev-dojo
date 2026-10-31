#!/usr/bin/env bash
# Verifier for "Autoscale Under Load". Inspects the live HorizontalPodAutoscaler
# spec; prints the flag only when every check passes. Exit 0 = solved, 1 = not yet.
set -uo pipefail

NS=dojo-hpa
FLAG='KUBE{hpa_replaces_the_pager}'

fail() { echo "✗ $1"; exit 1; }

kubectl get ns "$NS" >/dev/null 2>&1 || fail "namespace '$NS' is missing — run setup.sh first"
kubectl -n "$NS" get deploy web >/dev/null 2>&1 || fail "Deployment 'web' not found in $NS — run setup.sh first"

# Find the HPA (autoscaling/v2) whose scaleTargetRef is Deployment/web.
HPA=""
for h in $(kubectl -n "$NS" get hpa -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  TK=$(kubectl -n "$NS" get hpa "$h" -o jsonpath='{.spec.scaleTargetRef.kind}' 2>/dev/null)
  TN=$(kubectl -n "$NS" get hpa "$h" -o jsonpath='{.spec.scaleTargetRef.name}' 2>/dev/null)
  if [ "$TK" = "Deployment" ] && [ "$TN" = "web" ]; then HPA="$h"; break; fi
done
[ -n "$HPA" ] || fail "no HorizontalPodAutoscaler in $NS targets Deployment 'web' (check spec.scaleTargetRef)"

# (3) a CPU Resource metric using averageUtilization.
MTYPE=$(kubectl -n "$NS" get hpa "$HPA" -o jsonpath='{.spec.metrics[?(@.resource.name=="cpu")].type}' 2>/dev/null)
[ "$MTYPE" = "Resource" ] || fail "HPA '$HPA' needs a metric of type Resource for cpu (found: ${MTYPE:-none})"

TTYPE=$(kubectl -n "$NS" get hpa "$HPA" -o jsonpath='{.spec.metrics[?(@.resource.name=="cpu")].resource.target.type}' 2>/dev/null)
[ "$TTYPE" = "Utilization" ] || fail "cpu metric must use averageUtilization (target.type must be Utilization, not AverageValue) — found: ${TTYPE:-none}"

UTIL=$(kubectl -n "$NS" get hpa "$HPA" -o jsonpath='{.spec.metrics[?(@.resource.name=="cpu")].resource.target.averageUtilization}' 2>/dev/null)
if ! [ "${UTIL:-0}" -ge 1 ] 2>/dev/null || ! [ "${UTIL:-0}" -le 90 ] 2>/dev/null; then
  fail "cpu averageUtilization target must be a sane 1..90 (brief suggests 50) — found: ${UTIL:-unset}"
fi

# (5) sane bounds: min >= 2, max <= 5, and real headroom (max > min).
MIN=$(kubectl -n "$NS" get hpa "$HPA" -o jsonpath='{.spec.minReplicas}' 2>/dev/null)
MAX=$(kubectl -n "$NS" get hpa "$HPA" -o jsonpath='{.spec.maxReplicas}' 2>/dev/null)
if ! [ "${MIN:-0}" -ge 2 ] 2>/dev/null; then
  fail "minReplicas must be >= 2 (never serve from a single pod) — found: ${MIN:-unset}"
fi
if ! [ "${MAX:-0}" -le 5 ] 2>/dev/null; then
  fail "maxReplicas must be <= 5 — found: ${MAX:-unset}"
fi
if ! [ "${MAX:-0}" -gt "${MIN:-0}" ] 2>/dev/null; then
  fail "maxReplicas ($MAX) must be greater than minReplicas ($MIN) so there is headroom to scale into"
fi

echo "✓ HPA found                : $HPA"
echo "✓ scaleTargetRef           : Deployment/web"
echo "✓ cpu metric type          : Resource / Utilization"
echo "✓ averageUtilization target: ${UTIL}%"
echo "✓ minReplicas              : $MIN"
echo "✓ maxReplicas              : $MAX"
echo
echo "The pager is retired — the control plane scales 'web' on demand now."
echo "Submit this flag in the platform:"
echo
echo "    $FLAG"
