#!/usr/bin/env bash
# Verifier for "Alloy — Wire the OTel Pipeline".
# Checks: Alloy or OTel Collector pod is Ready AND its ConfigMap contains
# receiver, processor, and exporter sections.  Exit 0 = solved, 1 = not yet.
set -uo pipefail

NS=dojo-lgtm
FLAG='KUBE{alloy_otel_pipeline_receiver_processor_exporter}'

fail() { echo "✗ $1"; exit 1; }

# ── 1. Namespace ─────────────────────────────────────────────────────────────
kubectl get ns "$NS" >/dev/null 2>&1 \
  || fail "namespace '$NS' is missing — run setup.sh first"

# ── 2. Collector workload Ready (Alloy DaemonSet/Deployment or OTel Deployment)
READY=0

# Alloy DaemonSet
ALLOY_DS=$(kubectl -n "$NS" get ds -l app.kubernetes.io/name=alloy \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -n "$ALLOY_DS" ]; then
  DESIRED=$(kubectl -n "$NS" get ds "$ALLOY_DS" \
    -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo 0)
  RDYDS=$(kubectl -n "$NS" get ds "$ALLOY_DS" \
    -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)
  [ "${RDYDS:-0}" -ge "${DESIRED:-1}" ] && READY=1
fi

# Alloy Deployment (if not DaemonSet)
if [ "$READY" -eq 0 ]; then
  ALLOY_DEP=$(kubectl -n "$NS" get deploy -l app.kubernetes.io/name=alloy \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [ -n "$ALLOY_DEP" ]; then
    RDYDEP=$(kubectl -n "$NS" get deploy "$ALLOY_DEP" \
      -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
    [ "${RDYDEP:-0}" -ge 1 ] && READY=1
  fi
fi

# OTel Collector Deployment
if [ "$READY" -eq 0 ]; then
  OTEL_DEP=$(kubectl -n "$NS" get deploy -l app.kubernetes.io/name=opentelemetry-collector \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [ -n "$OTEL_DEP" ]; then
    RDYOTEL=$(kubectl -n "$NS" get deploy "$OTEL_DEP" \
      -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
    [ "${RDYOTEL:-0}" -ge 1 ] && READY=1
  fi
fi

[ "$READY" -eq 1 ] \
  || fail "no Alloy or OTel Collector workload is Ready in $NS (expected label app.kubernetes.io/name=alloy or opentelemetry-collector) — check: kubectl -n $NS get pods"

# ── 3. ConfigMap contains receiver + processor + exporter ────────────────────
# Iterate ConfigMaps with the right name label; fall back to any CM in NS.
HAS_PIPELINE=0
PIPELINE_CM=""

while IFS= read -r cm_name; do
  [ -z "$cm_name" ] && continue
  cm_data=$(kubectl -n "$NS" get cm "$cm_name" \
    -o jsonpath='{range .data.*}{@}{"\n"}{end}' 2>/dev/null || true)
  has_rx=$(echo "$cm_data" | grep -ic 'receiver' || true)
  has_pr=$(echo "$cm_data" | grep -ic 'processor' || true)
  has_ex=$(echo "$cm_data" | grep -ic 'exporter' || true)
  if [ "${has_rx:-0}" -ge 1 ] && [ "${has_pr:-0}" -ge 1 ] && [ "${has_ex:-0}" -ge 1 ]; then
    HAS_PIPELINE=1
    PIPELINE_CM="$cm_name"
    break
  fi
done < <(kubectl -n "$NS" get cm \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)

[ "$HAS_PIPELINE" -eq 1 ] \
  || fail "no ConfigMap in $NS contains all three of: receiver, processor, exporter — check your Alloy/OTel values file"

# ── All checks passed ─────────────────────────────────────────────────────────
echo "✓ Collector workload Ready    : yes (in $NS)"
echo "✓ Pipeline ConfigMap          : $PIPELINE_CM"
echo "✓ Has receiver                : yes"
echo "✓ Has processor               : yes"
echo "✓ Has exporter                : yes"
echo
echo "All checks passed. Submit this flag in the platform:"
echo
echo "    $FLAG"
