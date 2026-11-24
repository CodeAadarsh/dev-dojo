#!/usr/bin/env bash
# verify.sh — Vault Dynamic Credentials
set -uo pipefail

NAMESPACE="dojo-sec-vault"
EXPECTED_HASH="$(cat "$(dirname "$0")/flag.sha256")"

fail() { echo "FAIL: $1" >&2; exit 1; }

# Check vault-client pod exists
kubectl get pod vault-client -n "$NAMESPACE" >/dev/null 2>&1 \
  || fail "vault-client pod not found — run setup.sh first"

# Check vault is running
VAULT_READY=$(kubectl get pod -n "$NAMESPACE" -l app=vault \
  -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)

[ "$VAULT_READY" = "True" ] \
  || fail "vault pod is not Ready yet — wait and retry"

# Read the secret from vault via exec
FLAG=$(kubectl exec vault-client -n "$NAMESPACE" -- \
  sh -c 'vault kv get -field=flag secret/dojo/challenge 2>/dev/null' 2>/dev/null) \
  || fail "could not read secret/dojo/challenge from Vault — did you write it? Run: vault kv put secret/dojo/challenge flag=KUBE{vault_dynamic_ttl_beats_static_secrets}"

[ -n "$FLAG" ] || fail "flag field empty in Vault secret"

ACTUAL_HASH=$(printf '%s' "$FLAG" | shasum -a 256 | awk '{print $1}')

[ "$ACTUAL_HASH" = "$EXPECTED_HASH" ] || fail "wrong flag"

echo "PASS"
