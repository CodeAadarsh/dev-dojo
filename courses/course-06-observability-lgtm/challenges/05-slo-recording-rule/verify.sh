#!/usr/bin/env bash
# Verifier for "SLO Recording Rule".
# Checks that a valid PrometheusRule with a recording rule exists in dojo-slo.
# Exit 0 = solved, exit 1 = not yet.
set -uo pipefail

NS=dojo-slo
FLAG='KUBE{recording_rule_is_the_sli_factory}'

fail() { echo "✗ $1"; exit 1; }

kubectl get ns "$NS" >/dev/null 2>&1 || fail "namespace '$NS' is missing — run setup.sh first"

# Find any PrometheusRule in the namespace
PR_NAME=$(kubectl -n "$NS" get prometheusrule -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -n "$PR_NAME" ] || fail "no PrometheusRule found in namespace '$NS'"

# Check apiVersion / kind
API=$(kubectl -n "$NS" get prometheusrule "$PR_NAME" -o jsonpath='{.apiVersion}' 2>/dev/null)
[ "$API" = "monitoring.coreos.com/v1" ] || fail "PrometheusRule apiVersion must be 'monitoring.coreos.com/v1' (found: ${API:-unset})"

# Check that at least one rule has a 'record' field (recording rule, not alerting)
RECORD_NAME=$(kubectl -n "$NS" get prometheusrule "$PR_NAME" \
  -o jsonpath='{.spec.groups[0].rules[0].record}' 2>/dev/null)
[ -n "$RECORD_NAME" ] || fail "no recording rule found — spec.groups[].rules[] must have a 'record:' field (not 'alert:')"

# Check expr is non-empty
EXPR=$(kubectl -n "$NS" get prometheusrule "$PR_NAME" \
  -o jsonpath='{.spec.groups[0].rules[0].expr}' 2>/dev/null)
[ -n "$EXPR" ] || fail "recording rule '$RECORD_NAME' has an empty 'expr' — provide a PromQL expression (e.g. a rate/ratio)"

# Verify the record name contains at least one colon (level:metric:operations convention)
case "$RECORD_NAME" in
  *:*) ;;
  *) fail "recording rule name '$RECORD_NAME' should follow the naming convention 'level:metric:operations' (e.g. job:http_request_success_ratio:rate5m)" ;;
esac

echo "✓ PrometheusRule            : $PR_NAME"
echo "✓ recording rule            : $RECORD_NAME"
echo "✓ expr                      : $EXPR"
echo
echo "All SLO recording rule checks passed. Submit this flag in the platform:"
echo
echo "    $FLAG"
