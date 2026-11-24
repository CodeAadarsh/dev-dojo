#!/usr/bin/env bash
# verify.sh — CI/CD Pipeline Injection
set -uo pipefail

NAMESPACE="dojo-sec-ci"
EXPECTED_HASH="$(cat "$(dirname "$0")/flag.sha256")"

fail() { echo "FAIL: $1" >&2; exit 1; }

kubectl get configmap ci-injection-flag -n "$NAMESPACE" >/dev/null 2>&1 \
  || fail "configmap ci-injection-flag not found"

STATUS=$(kubectl get configmap ci-injection-flag -n "$NAMESPACE" \
  -o jsonpath='{.data.status}' 2>/dev/null)

[ "$STATUS" = "pending — run the CI executor pod with your injection payload" ] \
  && fail "injection not completed — the flag configmap was not updated"

FLAG=$(kubectl get configmap ci-injection-flag -n "$NAMESPACE" \
  -o jsonpath='{.data.flag}' 2>/dev/null)

[ -n "$FLAG" ] || fail "flag key not found in ci-injection-flag configmap"

ACTUAL_HASH=$(printf '%s' "$FLAG" | shasum -a 256 | awk '{print $1}')

[ "$ACTUAL_HASH" = "$EXPECTED_HASH" ] || fail "wrong flag"

echo "PASS"
