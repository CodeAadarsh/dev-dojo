# Vault: Read a Secret Under a Scoped Policy

During a post-incident review the security team found that a service account token had
`capabilities = ["read"]` on `secret/data/*` — a wildcard that let a compromised service
read any secret in the cluster, including credentials belonging to a completely different
team. Vault's power is its policy model; that power only materialises when the policy is
narrow.

Your task is to operationalise the lesson: write a secret to a specific path, craft a
policy that permits exactly that path and nothing else, create a token bound to that
policy, and prove the deny — because a policy you haven't tested for denial is just
good intentions.

## Prerequisites

Docker must be running. `setup.sh` launches a Vault dev server:

```bash
docker run -d --name dojo-vault \
  -e VAULT_DEV_ROOT_TOKEN_ID=dojo \
  -p 8200:8200 \
  hashicorp/vault:1.17
```

Install the Vault CLI if you do not have it:

```bash
# macOS
brew install vault

# or download the binary directly:
# https://releases.hashicorp.com/vault/
```

Run setup once the container is up:

```bash
bash courses/course-31-secrets-zero-trust/challenges/04-vault-read-a-secret/setup.sh
```

## Mission

With `VAULT_ADDR=http://127.0.0.1:8200` and `VAULT_TOKEN=dojo` (the root token, for setup
only):

1. **Enable the KV v2 secrets engine** at path `dojo-kv` (if not already enabled).
2. **Write a secret** at `dojo-kv/data/app/config` with at least the key `api_key`.
3. **Author and write a policy** named `dojo-app-reader` that grants `read` on
   `dojo-kv/data/app/config` and nothing else.
4. **Create a token** bound to the `dojo-app-reader` policy.
5. Using **only that scoped token** (not root):
   - Confirm you can read `dojo-kv/data/app/config`.
   - Confirm you are **denied** on `dojo-kv/data/other/config`.

`verify.sh` drives the same sequence against the live container and issues the flag when
every assertion passes.

## Why this matters

A Vault policy is the boundary between "the service can read its own secret" and "the
service can read everyone's secrets." Vault evaluates policies by **explicit deny-wins**:
if no policy grants a capability, the request is denied. A wildcard path in a policy
statement (`secret/data/*`) defeats this entirely — any lateral move within the token's
lifetime gives the attacker free access to every secret in the engine.

The rule: **one policy per service, one path per policy statement, and test the deny.**

## Verify

```bash
bash courses/course-31-secrets-zero-trust/challenges/04-vault-read-a-secret/verify.sh
```
