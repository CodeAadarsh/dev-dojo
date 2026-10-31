#!/usr/bin/env bash
# Verifier for "Dashboard as Code".
# Checks that a ConfigMap with label grafana_dashboard=1 exists in dojo-dash
# and contains dashboard JSON with a non-empty panels array.
# Exit 0 = solved, exit 1 = not yet.
set -uo pipefail

NS=dojo-dash
FLAG='KUBE{dashboard_as_code_grafana_sidecar}'

fail() { echo "✗ $1"; exit 1; }

kubectl get ns "$NS" >/dev/null 2>&1 || fail "namespace '$NS' is missing — run setup.sh first"

# Find a ConfigMap with the grafana_dashboard label in dojo-dash
CM_NAME=$(kubectl -n "$NS" get configmap -l 'grafana_dashboard=1' \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -n "$CM_NAME" ] || fail "no ConfigMap with label 'grafana_dashboard=1' found in namespace '$NS'"

# Check the label value is exactly "1"
LABEL_VAL=$(kubectl -n "$NS" get configmap "$CM_NAME" \
  -o jsonpath='{.metadata.labels.grafana_dashboard}' 2>/dev/null)
[ "$LABEL_VAL" = "1" ] || fail "label grafana_dashboard must equal '1' (found: ${LABEL_VAL:-unset})"

# Get the first data key name
DATA_KEY=$(kubectl -n "$NS" get configmap "$CM_NAME" \
  -o jsonpath='{.data}' 2>/dev/null)
[ -n "$DATA_KEY" ] || fail "ConfigMap '$CM_NAME' has no data keys — add a key with dashboard JSON as the value"

# Get the value of the first data key (the dashboard JSON string)
DASHBOARD_JSON=$(kubectl -n "$NS" get configmap "$CM_NAME" \
  -o jsonpath='{.data}' 2>/dev/null)

# Check that the raw data output contains "panels" as a JSON key
echo "$DASHBOARD_JSON" | grep -q '"panels"' \
  || fail "ConfigMap data does not contain a '\"panels\"' key — the value must be valid Grafana dashboard JSON"

# Check that panels is not an empty array by looking for content after "panels":
PANELS_CONTENT=$(kubectl -n "$NS" get configmap "$CM_NAME" \
  -o jsonpath='{.data}' 2>/dev/null | grep -o '"panels":\[[^]]*\]' | head -1)
[ -n "$PANELS_CONTENT" ] || fail "the 'panels' array appears to be empty or malformed — add at least one panel object"

echo "✓ ConfigMap                 : $CM_NAME"
echo "✓ label grafana_dashboard   : 1"
echo "✓ dashboard JSON key        : found"
echo "✓ panels array              : non-empty"
echo
echo "All dashboard checks passed. Submit this flag in the platform:"
echo
echo "    $FLAG"
