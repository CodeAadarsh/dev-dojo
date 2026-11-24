#!/usr/bin/env bash
# verify.sh — kube-bench CIS Hardening
set -uo pipefail

NAMESPACE="dojo-sec-bench"
EXPECTED_HASH="$(cat "$(dirname "$0")/flag.sha256")"

fail() { echo "FAIL: $1" >&2; exit 1; }

# Confirm the offending CRB was actually deleted
kubectl get clusterrolebinding overprivileged-binding >/dev/null 2>&1 \
  && fail "ClusterRoleBinding 'overprivileged-binding' still exists — delete it: kubectl delete clusterrolebinding overprivileged-binding"

# Check the flag configmap was written by the watcher
kubectl get configmap cis-hardening-flag -n "$NAMESPACE" >/dev/null 2>&1 \
  || fail "cis-hardening-flag configmap not found — did the watcher pod detect the deletion? Check: kubectl logs bench-watcher -n $NAMESPACE"

FLAG=$(kubectl get configmap cis-hardening-flag -n "$NAMESPACE" \
  -o jsonpath='{.data.flag}' 2>/dev/null)

[ -n "$FLAG" ] || fail "flag key missing from cis-hardening-flag configmap"

ACTUAL_HASH=$(printf '%s' "$FLAG" | shasum -a 256 | awk '{print $1}')

[ "$ACTUAL_HASH" = "$EXPECTED_HASH" ] || fail "wrong flag"

echo "PASS"
