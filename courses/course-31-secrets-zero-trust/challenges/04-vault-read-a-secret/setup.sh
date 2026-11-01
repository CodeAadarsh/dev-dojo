#!/usr/bin/env bash
# Sets up the Vault dev server and seeds a baseline KV v2 engine.
# The learner must author the policy, create the token, and prove the deny.
set -euo pipefail

VAULT_ADDR="http://127.0.0.1:8200"
VAULT_TOKEN="dojo"
export VAULT_ADDR VAULT_TOKEN

echo "==> Checking Docker..."
if ! docker info >/dev/null 2>&1; then
  echo "✗ Docker is not running. Start Docker Desktop first."
  exit 1
fi

echo "==> Starting Vault dev server (idempotent)..."
if docker ps --format '{{.Names}}' | grep -q '^dojo-vault$'; then
  echo "    dojo-vault container already running — skipping docker run."
else
  docker rm -f dojo-vault 2>/dev/null || true
  docker run -d --name dojo-vault \
    -e VAULT_DEV_ROOT_TOKEN_ID=dojo \
    -p 8200:8200 \
    hashicorp/vault:1.17
  echo "    Waiting for Vault to initialise..."
  for i in $(seq 1 20); do
    if curl -sf "${VAULT_ADDR}/v1/sys/health" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
fi

echo "==> Enabling KV v2 at path 'dojo-kv' (idempotent)..."
docker exec dojo-vault \
  sh -c "VAULT_ADDR=${VAULT_ADDR} VAULT_TOKEN=${VAULT_TOKEN} \
         vault secrets enable -path=dojo-kv kv-v2" 2>/dev/null || true

echo
echo "Vault is ready."
echo
echo "  VAULT_ADDR=${VAULT_ADDR}"
echo "  VAULT_TOKEN=${VAULT_TOKEN}   (root — for setup/admin only)"
echo
echo "Your tasks:"
echo "  1. Write a secret:  vault kv put dojo-kv/app/config api_key=supersecret"
echo "  2. Author a policy file (dojo-app-reader.hcl):"
echo '       path "dojo-kv/data/app/config" { capabilities = ["read"] }'
echo "  3. Write the policy: vault policy write dojo-app-reader dojo-app-reader.hcl"
echo "  4. Create a scoped token: vault token create -policy=dojo-app-reader -field=token"
echo "  5. With that token:"
echo "       VAULT_TOKEN=<scoped> vault kv get dojo-kv/app/config   # must succeed"
echo "       VAULT_TOKEN=<scoped> vault kv get dojo-kv/other/config # must be denied"
echo
echo "Run the verifier when done:"
echo "  bash courses/course-31-secrets-zero-trust/challenges/04-vault-read-a-secret/verify.sh"
