#!/usr/bin/env bash
# Verifier for "Dashboards and Alerts as Code".
# Checks: a ConfigMap labeled grafana_dashboard=1 with "panels" in its data,
# AND either a PrometheusRule or a ConfigMap labeled grafana_alerts=1 with
# alert rule content.  Exit 0 = solved, 1 = not yet.
set -uo pipefail

NS=dojo-lgtm
FLAG='KUBE{dashboards_and_alerts_as_code}'

fail() { echo "✗ $1"; exit 1; }

# ── 1. Namespace ─────────────────────────────────────────────────────────────
kubectl get ns "$NS" >/dev/null 2>&1 \
  || fail "namespace '$NS' is missing — run setup.sh first"

# ── 2. Dashboard ConfigMap (label grafana_dashboard=1, data contains "panels")
DASH_CM=$(kubectl -n "$NS" get cm -l grafana_dashboard=1 \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
[ -n "$DASH_CM" ] \
  || fail "no ConfigMap with label grafana_dashboard=1 found in $NS — create one with kubectl apply"

PANELS_HIT=$(kubectl -n "$NS" get cm "$DASH_CM" \
  -o jsonpath='{range .data.*}{@}{"\n"}{end}' 2>/dev/null \
  | grep -c '"panels"' || true)
[ "${PANELS_HIT:-0}" -ge 1 ] \
  || fail "ConfigMap '$DASH_CM' exists but its data doesn't contain \"panels\" — the value must be valid Grafana dashboard JSON"

# ── 3. Alert rule — PrometheusRule OR labeled ConfigMap ──────────────────────
ALERT_SOURCE=""

# 3a. PrometheusRule (prometheus-operator CRD) — only check if CRD is present
if kubectl api-resources --api-group=monitoring.coreos.com 2>/dev/null | grep -q PrometheusRule; then
  PR_NAME=$(kubectl -n "$NS" get prometheusrule \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  [ -n "$PR_NAME" ] && ALERT_SOURCE="PrometheusRule/$PR_NAME"
fi

# 3b. Grafana alert provisioning ConfigMap (label grafana_alerts=1)
if [ -z "$ALERT_SOURCE" ]; then
  ALERT_CM=$(kubectl -n "$NS" get cm -l grafana_alerts=1 \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [ -n "$ALERT_CM" ]; then
    CM_DATA=$(kubectl -n "$NS" get cm "$ALERT_CM" \
      -o jsonpath='{range .data.*}{@}{"\n"}{end}' 2>/dev/null || true)
    HAS_GROUPS=$(echo "$CM_DATA" | grep -ic 'groups' || true)
    HAS_ALERT=$(echo "$CM_DATA" | grep -ic 'alert' || true)
    if [ "${HAS_GROUPS:-0}" -ge 1 ] && [ "${HAS_ALERT:-0}" -ge 1 ]; then
      ALERT_SOURCE="ConfigMap/$ALERT_CM"
    else
      fail "ConfigMap '$ALERT_CM' has label grafana_alerts=1 but its data doesn't contain both 'groups' and 'alert' — check the provisioning YAML format"
    fi
  fi
fi

[ -n "$ALERT_SOURCE" ] \
  || fail "no alert rule found in $NS — create a PrometheusRule OR a ConfigMap with label grafana_alerts=1 containing groups + alert rule YAML"

# ── All checks passed ─────────────────────────────────────────────────────────
echo "✓ Dashboard ConfigMap         : $DASH_CM (label grafana_dashboard=1)"
echo "✓ Dashboard JSON has 'panels' : yes"
echo "✓ Alert rule object           : $ALERT_SOURCE"
echo
echo "All checks passed. Submit this flag in the platform:"
echo
echo "    $FLAG"
