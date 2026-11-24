# Vault Dynamic Credentials

Your team just discovered that all 12 of your production services are sharing the same hardcoded database password — a password that hasn't been rotated in 18 months. If any one of those services is compromised, the attacker has permanent database access.

This challenge sets up HashiCorp Vault in dev mode with a simulated database backend. You'll:
1. Connect to Vault and generate a dynamic credential
2. Watch it expire (or revoke it early)
3. Generate a second credential — it's completely different
4. Prove you understand the model by reading the flag from a Vault path

## Why Dynamic Secrets Win

```
Static secret:              Dynamic secret (Vault):
  password: supersecret       Generated at request time
  valid: forever              Valid for 1 hour
  shared by all pods          Unique per pod per request
  no audit trail              Full audit log
  manual rotation             Auto-revoked at TTL
```

## Setup

Vault is deployed as a Pod in `dojo-sec-vault`. It runs in dev mode with the root token `root`.

```bash
# Port-forward to Vault
kubectl port-forward -n dojo-sec-vault svc/vault 8200:8200 &
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=root

# Verify it's running
vault status
```

## Mission

1. Port-forward to Vault
2. Generate a dynamic credential: `vault read database/creds/app-role`
3. Note the `lease_id`
4. Revoke it: `vault lease revoke <lease_id>`
5. Generate a new credential — verify it's different
6. Read the flag: `vault kv get secret/dojo/flag`

## Rules of Engagement

- Namespace: `dojo-sec-vault`
- Vault root token: `root`
- Port-forward: `kubectl port-forward -n dojo-sec-vault svc/vault 8200:8200`
- Flag location: `vault kv get secret/dojo/flag`
- Run verify.sh when done to confirm the setup worked
