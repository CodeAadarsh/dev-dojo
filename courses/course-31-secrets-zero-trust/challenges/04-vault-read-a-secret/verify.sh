#!/usr/bin/env bash
# Verifier for "Vault: Read a Secret Under a Scoped Policy".
# Uses docker exec to drive vault CLI inside the container — no local vault CLI required.
# Checks:
#   1. KV v2 engine enabled at dojo-kv
#   2. Secret exists at dojo-kv/data/app/config with key api_key
#   3. Policy dojo-app-reader exists with a path rule for dojo-kv/data/app/config
#   4. A token scoped to dojo-app-reader can READ  dojo-kv/app/config
#   5. That same token is DENIED on dojo-kv/other/config
set -uo pipefail

VAULT_ADDR="http://127.0.0.1:8200"
ROOT_TOKEN="dojo"
FLAG='KUBE{vault_policy_least_privilege}'

fail() { echo "✗ $1"; exit 1; }

# ── prereq: container running ─────────────────────────────────────────────────
docker ps --format '{{.Names}}' | grep -q '^dojo-vault$' \
  || fail "dojo-vault container is not running — run setup.sh first"

vexec() {
  # Run a vault command inside the container with the provided token
  local token="$1"; shift
  docker exec dojo-vault \
    sh -c "VAULT_ADDR=${VAULT_ADDR} VAULT_TOKEN=${token} vault $*"
}

# ── 1. KV v2 engine enabled at dojo-kv ───────────────────────────────────────
echo "--> checking KV v2 engine at dojo-kv..."
vexec "$ROOT_TOKEN" secrets list -format=table 2>&1 \
  | grep -q 'dojo-kv/' \
  || fail "KV v2 engine not enabled at 'dojo-kv' — run: vault secrets enable -path=dojo-kv kv-v2"

# ── 2. Secret exists at dojo-kv/app/config ───────────────────────────────────
echo "--> checking secret at dojo-kv/app/config..."
SECRET_OUT=$(vexec "$ROOT_TOKEN" kv get -format=table dojo-kv/app/config 2>&1) \
  || fail "Secret not found at dojo-kv/app/config — run: vault kv put dojo-kv/app/config api_key=<value>"
echo "$SECRET_OUT" | grep -q 'api_key' \
  || fail "Secret at dojo-kv/app/config must have key 'api_key'"

# ── 3. Policy dojo-app-reader exists ─────────────────────────────────────────
echo "--> checking policy dojo-app-reader..."
POLICY_OUT=$(vexec "$ROOT_TOKEN" policy read dojo-app-reader 2>&1) \
  || fail "Policy 'dojo-app-reader' not found — write it with: vault policy write dojo-app-reader <file.hcl>"
echo "$POLICY_OUT" | grep -q 'dojo-kv/data/app/config' \
  || fail "Policy 'dojo-app-reader' must contain a rule for path 'dojo-kv/data/app/config'"

# ── 4. Create a short-lived test token bound to the policy ───────────────────
echo "--> minting a scoped token for dojo-app-reader..."
SCOPED_TOKEN=$(vexec "$ROOT_TOKEN" token create -policy=dojo-app-reader -ttl=5m -field=token 2>&1) \
  || fail "Failed to create token with policy dojo-app-reader"
SCOPED_TOKEN=$(echo "$SCOPED_TOKEN" | tr -d '[:space:]')
[ -n "$SCOPED_TOKEN" ] || fail "Scoped token is empty — something went wrong with token creation"

# ── 5. Scoped token CAN read the allowed path ─────────────────────────────────
echo "--> verifying scoped token can read dojo-kv/app/config..."
vexec "$SCOPED_TOKEN" kv get dojo-kv/app/config >/dev/null 2>&1 \
  || fail "Scoped token was denied on dojo-kv/app/config — check the policy path"

# ── 6. Scoped token is DENIED on a different path ────────────────────────────
echo "--> verifying scoped token is denied on dojo-kv/other/config..."
DENY_OUT=$(vexec "$SCOPED_TOKEN" kv get dojo-kv/other/config 2>&1) && {
  fail "Scoped token was NOT denied on dojo-kv/other/config — your policy is too broad (wildcard?)"
} || true
echo "$DENY_OUT" | grep -q -i 'permission denied' \
  || fail "Expected 'permission denied' on dojo-kv/other/config but got unexpected output: $DENY_OUT"

# ── All checks passed ─────────────────────────────────────────────────────────
echo
echo "All checks passed. Submit this flag in the platform:"
echo
echo "    $FLAG"
