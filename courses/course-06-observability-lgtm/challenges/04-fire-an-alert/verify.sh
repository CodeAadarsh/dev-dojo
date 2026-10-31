#!/usr/bin/env bash
# Verifier for "Fire an Alert".
# Checks that a valid PrometheusRule with an alerting rule exists in dojo-alert.
# Exit 0 = solved, exit 1 = not yet.
set -uo pipefail

NS=dojo-alert
FLAG='KUBE{alerting_rule_fires_on_purpose}'

fail() { echo "✗ $1"; exit 1; }

kubectl get ns "$NS" >/dev/null 2>&1 || fail "namespace '$NS' is missing — run setup.sh first"

# Find any PrometheusRule in the namespace
PR_NAME=$(kubectl -n "$NS" get prometheusrule -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -n "$PR_NAME" ] || fail "no PrometheusRule found in namespace '$NS'"

# Check apiVersion / kind
API=$(kubectl -n "$NS" get prometheusrule "$PR_NAME" -o jsonpath='{.apiVersion}' 2>/dev/null)
[ "$API" = "monitoring.coreos.com/v1" ] || fail "PrometheusRule apiVersion must be 'monitoring.coreos.com/v1' (found: ${API:-unset})"

# Check that at least one rule has an 'alert' field (alerting rule, not recording)
ALERT_NAME=$(kubectl -n "$NS" get prometheusrule "$PR_NAME" \
  -o jsonpath='{.spec.groups[0].rules[0].alert}' 2>/dev/null)
[ -n "$ALERT_NAME" ] || fail "no alerting rule found — spec.groups[].rules[] must have an 'alert:' field (not 'record:')"

# Check expr is non-empty
EXPR=$(kubectl -n "$NS" get prometheusrule "$PR_NAME" \
  -o jsonpath='{.spec.groups[0].rules[0].expr}' 2>/dev/null)
[ -n "$EXPR" ] || fail "alerting rule '$ALERT_NAME' has an empty 'expr' — provide a PromQL expression"

# Check 'for' duration is set
FOR_FIELD=$(kubectl -n "$NS" get prometheusrule "$PR_NAME" \
  -o jsonpath='{.spec.groups[0].rules[0].for}' 2>/dev/null)
[ -n "$FOR_FIELD" ] || fail "alerting rule '$ALERT_NAME' is missing a 'for:' duration (e.g. for: 1m)"

# Check severity label
SEVERITY=$(kubectl -n "$NS" get prometheusrule "$PR_NAME" \
  -o jsonpath='{.spec.groups[0].rules[0].labels.severity}' 2>/dev/null)
[ -n "$SEVERITY" ] || fail "alerting rule '$ALERT_NAME' is missing labels.severity (e.g. severity: warning)"

# Check annotations.summary
SUMMARY=$(kubectl -n "$NS" get prometheusrule "$PR_NAME" \
  -o jsonpath='{.spec.groups[0].rules[0].annotations.summary}' 2>/dev/null)
[ -n "$SUMMARY" ] || fail "alerting rule '$ALERT_NAME' is missing annotations.summary"

echo "✓ PrometheusRule            : $PR_NAME"
echo "✓ alerting rule             : $ALERT_NAME"
echo "✓ expr                      : $EXPR"
echo "✓ for duration              : $FOR_FIELD"
echo "✓ severity label            : $SEVERITY"
echo "✓ annotations.summary       : $SUMMARY"
echo
echo "All alerting checks passed. Submit this flag in the platform:"
echo
echo "    $FLAG"
