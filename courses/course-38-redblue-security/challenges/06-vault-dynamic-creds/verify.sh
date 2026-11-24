#!/usr/bin/env bash
set -uo pipefail

NAMESPACE="dojo-sec-vault"
fail() { echo "FAIL: $*"; exit 1; }

echo "==> Verifying: Vault Dynamic Credentials"

# Check namespace
kubectl get namespace "$NAMESPACE" > /dev/null 2>&1 || fail "Namespace $NAMESPACE not found — run setup.sh first"

# Check Vault pod is running
VAULT_POD=$(kubectl get pod -n "$NAMESPACE" -l app=vault -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -n "$VAULT_POD" ] || fail "Vault pod not found in $NAMESPACE — run setup.sh first"

VAULT_STATUS=$(kubectl get pod "$VAULT_POD" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null)
[ "$VAULT_STATUS" = "Running" ] || fail "Vault pod is not Running (status: $VAULT_STATUS)"

echo "    Vault pod: $VAULT_POD ($VAULT_STATUS)"

# Check flag is accessible via exec into Vault pod
FLAG=$(kubectl exec -n "$NAMESPACE" "$VAULT_POD" -- \
  sh -c 'VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root vault kv get -field=value secret/dojo/flag' 2>/dev/null) || \
  fail "Could not read secret/dojo/flag from Vault — check if setup job completed"

[ -n "$FLAG" ] || fail "Flag is empty in Vault — run the setup job"

echo ""
echo "==> Vault is running. Dynamic credentials model is configured."
echo "    Port-forward: kubectl port-forward -n $NAMESPACE svc/vault 8200:8200"
echo "    Then: VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=root vault kv get secret/dojo/flag"
echo ""
echo "$FLAG"
