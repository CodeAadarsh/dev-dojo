# Solution — Vault: Read a Secret Under a Scoped Policy

The flag is `KUBE{vault_policy_least_privilege}`.

## Setup

```bash
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=dojo   # root token, used only for admin operations below
```

## Step 1 — Enable KV v2 at dojo-kv

```bash
vault secrets enable -path=dojo-kv kv-v2
# Success! Enabled the kv-v2 secrets engine at: dojo-kv/
```

KV v2 stores versions. Every `vault kv put` creates a new version under `data/`; `metadata/` holds version history. The policy must target `data/` explicitly — `dojo-kv/data/app/config`, not `dojo-kv/app/config` — because the HTTP API Vault evaluates policies against is the `data/` sub-path.

## Step 2 — Write the secret

```bash
vault kv put dojo-kv/app/config api_key=supersecret
```

Verify it round-trips:

```bash
vault kv get dojo-kv/app/config
```

## Step 3 — Author the policy

Write `dojo-app-reader.hcl`:

```hcl
path "dojo-kv/data/app/config" {
  capabilities = ["read"]
}
```

**Why not `"list"`?** List on `dojo-kv/metadata/` would expose the names of every other secret in the engine. The principle of least privilege: grant only `read` on the exact path the service needs.

Apply it:

```bash
vault policy write dojo-app-reader dojo-app-reader.hcl
# Success! Uploaded policy: dojo-app-reader
```

Inspect it to confirm the path rule:

```bash
vault policy read dojo-app-reader
```

## Step 4 — Create a scoped token

```bash
SCOPED=$(vault token create -policy=dojo-app-reader -ttl=1h -field=token)
echo $SCOPED
```

Inspect the token's capabilities before using it:

```bash
vault token capabilities $SCOPED dojo-kv/data/app/config
# read
vault token capabilities $SCOPED dojo-kv/data/other/config
# deny
```

## Step 5 — Read with the scoped token, prove the deny

Read the allowed path:

```bash
VAULT_TOKEN=$SCOPED vault kv get dojo-kv/app/config
# Key          Value
# api_key      supersecret
```

Attempt the disallowed path:

```bash
VAULT_TOKEN=$SCOPED vault kv get dojo-kv/other/config
# Error reading dojo-kv/data/other/config: Error making API request.
# URL: GET http://127.0.0.1:8200/v1/dojo-kv/data/other/config
# Code: 403. Errors:
# * 1 error occurred:
#     * permission denied
```

`403 permission denied` is the intended result. An untested deny is not a security control.

## Attacker's view

An attacker who obtains this token can read `dojo-kv/data/app/config` but nothing else.
The blast radius is the lifetime of the token (`-ttl=1h`). Vault's lease system means short-lived tokens + auto-rotation dramatically shrinks the window for lateral movement compared to a static `VAULT_TOKEN` in a Kubernetes Secret that never rotates.

## Hardening preview

- Use `vault token create -policy=... -use-limit=1` for one-shot secrets.
- Prefer **AppRole** or **Kubernetes auth** over manual token creation — the pod authenticates with its ServiceAccount JWT and Vault issues a short-lived token automatically.
- Enable **token accessor logging** (`vault audit enable file file_path=/vault/logs/audit.log`) so every secret read is auditable.
