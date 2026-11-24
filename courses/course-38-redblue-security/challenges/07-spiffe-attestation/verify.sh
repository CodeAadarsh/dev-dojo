#!/usr/bin/env bash
# verify.sh — SPIFFE/SPIRE Attestation
set -uo pipefail

NAMESPACE="dojo-sec-spiffe"
EXPECTED_HASH="$(cat "$(dirname "$0")/flag.sha256")"

fail() { echo "FAIL: $1" >&2; exit 1; }

# Check secret exists
kubectl get secret workload-svid -n "$NAMESPACE" >/dev/null 2>&1 \
  || fail "workload-svid secret not found — wait for setup job to complete (kubectl get job spiffe-cert-generator -n $NAMESPACE)"

# Extract the spiffe-id field
SPIFFE_ID=$(kubectl get secret workload-svid -n "$NAMESPACE" \
  -o jsonpath='{.data.spiffe-id}' 2>/dev/null | base64 -d 2>/dev/null)

[ -n "$SPIFFE_ID" ] || fail "spiffe-id field missing from workload-svid secret"

# Extract the flag from the service account name part of the SPIFFE ID
# SPIFFE ID format: spiffe://trust-domain/ns/namespace/sa/<service-account>
# The service-account contains the flag text with underscores
SA_PART=$(printf '%s' "$SPIFFE_ID" | sed 's|.*/sa/||')

[ -n "$SA_PART" ] || fail "could not parse service account from SPIFFE ID"

# Reconstruct the flag: KUBE_prefix → KUBE{...}
FLAG=$(printf '%s' "$SA_PART" | sed 's/KUBE_/KUBE{/' | sed 's/$/_/' | sed 's/_$/}/')

ACTUAL_HASH=$(printf '%s' "$FLAG" | shasum -a 256 | awk '{print $1}')

[ "$ACTUAL_HASH" = "$EXPECTED_HASH" ] || fail "wrong flag — SPIFFE ID was: $SPIFFE_ID"

echo "PASS"
