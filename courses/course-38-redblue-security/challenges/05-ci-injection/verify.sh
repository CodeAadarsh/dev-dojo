#!/usr/bin/env bash
# verify.sh — CI/CD Pipeline Injection
set -uo pipefail

NAMESPACE="dojo-sec-ci"
EXPECTED_HASH="$(cat "$(dirname "$0")/flag.sha256")"

fail() { echo "FAIL: $1" >&2; exit 1; }

kubectl get configmap ci-output -n "$NAMESPACE" >/dev/null 2>&1 \
  || fail "configmap ci-output not found in $NAMESPACE — run setup.sh first"

# Decode the base64 blob from the simulated CI output
OUTPUT=$(kubectl get configmap ci-output -n "$NAMESPACE" \
  -o jsonpath='{.data.output}' 2>/dev/null)

[ -n "$OUTPUT" ] || fail "output key missing from ci-output configmap"

# Extract the base64 blob — the long alphanumeric line ending in ==
B64_BLOB=$(printf '%s' "$OUTPUT" | grep -E '^[A-Za-z0-9+/]+==$' | head -1)

[ -n "$B64_BLOB" ] || fail "base64 blob not found in ci-output — look for a line ending in == in the output field"

FLAG=$(printf '%s' "$B64_BLOB" | base64 -d 2>/dev/null)

[ -n "$FLAG" ] || fail "failed to base64-decode the blob"

ACTUAL_HASH=$(printf '%s' "$FLAG" | shasum -a 256 | awk '{print $1}')

[ "$ACTUAL_HASH" = "$EXPECTED_HASH" ] || fail "decoded content is not the flag — got: $FLAG"

echo "PASS: $FLAG"
