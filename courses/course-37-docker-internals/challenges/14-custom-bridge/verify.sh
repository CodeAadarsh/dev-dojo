#!/usr/bin/env bash
set -uo pipefail

NAMESPACE="dojo-docker-bridge"

fail() {
  echo "FAIL: $1"
  exit 1
}

echo "==> Verifying: Custom Bridge Isolation"

# Check 1: Docker network dojo-isolated exists
if ! docker network ls --format '{{.Name}}' | grep -q "^dojo-isolated$"; then
  fail "Docker network 'dojo-isolated' does not exist. Create it with: docker network create --driver bridge dojo-isolated"
fi
echo "    [OK] Docker network dojo-isolated exists"

# Check 2: ConfigMap network-proof has isolated_network=dojo-isolated
ISOLATED=$(kubectl get configmap network-proof -n "$NAMESPACE" \
  -o jsonpath='{.data.isolated_network}' 2>/dev/null || echo "")
if [ "$ISOLATED" != "dojo-isolated" ]; then
  fail "ConfigMap 'network-proof' data.isolated_network must be 'dojo-isolated' (got: '${ISOLATED}'). Update it: kubectl patch configmap network-proof -n $NAMESPACE -p '{\"data\":{\"isolated_network\":\"dojo-isolated\"}}'"
fi
echo "    [OK] ConfigMap network-proof updated"

echo ""
echo "    Flag: KUBE{custom_bridge_isolates_traffic}"
