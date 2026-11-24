#!/usr/bin/env bash
set -uo pipefail

NAMESPACE="dojo-sec-spiffe"
TARGET_SPIFFE_ID="spiffe://cluster.local/ns/dojo-sec-spiffe/sa/spiffe-sa"
fail() { echo "FAIL: $*"; exit 1; }

echo "==> Verifying: SPIFFE Attestation"

# Check namespace
kubectl get namespace "$NAMESPACE" > /dev/null 2>&1 || fail "Namespace $NAMESPACE not found — run setup.sh first"

# Check SPIRE server pod exists and is running
SPIRE_POD=$(kubectl get pod spire-server-0 -n "$NAMESPACE" -o jsonpath='{.metadata.name}' 2>/dev/null || echo "")
[ -n "$SPIRE_POD" ] || fail "spire-server-0 not found in $NAMESPACE — run setup.sh first"

SPIRE_STATUS=$(kubectl get pod spire-server-0 -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null)
[ "$SPIRE_STATUS" = "Running" ] || fail "SPIRE server pod is not Running (status: $SPIRE_STATUS)"

echo "    SPIRE server: $SPIRE_STATUS"

# Check if the workload entry exists
ENTRY_OUTPUT=$(kubectl exec -n "$NAMESPACE" spire-server-0 -- \
  /opt/spire/bin/spire-server entry show 2>/dev/null || echo "")

if echo "$ENTRY_OUTPUT" | grep -q "$TARGET_SPIFFE_ID"; then
  echo "    Workload entry found: $TARGET_SPIFFE_ID"
else
  fail "Workload entry not found. Register it first:
  kubectl exec -n $NAMESPACE spire-server-0 -- \\
    /opt/spire/bin/spire-server entry create \\
    -spiffeID $TARGET_SPIFFE_ID \\
    -parentID spiffe://cluster.local/spire/agent/k8s_psat/kube-dojo/\$(kubectl get node -o jsonpath='{.items[0].metadata.uid}') \\
    -selector k8s:ns:dojo-sec-spiffe \\
    -selector k8s:sa:spiffe-sa"
fi

# Read the flag
FLAG_B64=$(kubectl get configmap spiffe-reward -n "$NAMESPACE" -o jsonpath='{.data.flag_b64}' 2>/dev/null)
[ -n "$FLAG_B64" ] || fail "Reward ConfigMap not found — run setup.sh first"
FLAG=$(printf '%s' "$FLAG_B64" | base64 -d)

echo ""
echo "==> SPIFFE workload entry registered successfully."
echo "    SVID will be issued to pods matching: ns=$NAMESPACE, sa=spiffe-sa"
echo ""
echo "$FLAG"
