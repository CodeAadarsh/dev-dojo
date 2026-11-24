# Vault Dynamic Credentials — Solution

## Step 1: Port-Forward to Vault

```bash
kubectl port-forward -n dojo-sec-vault svc/vault 8200:8200 &
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=root

vault status
```

Output:
```
Key             Value
---             -----
Seal Type       shamir
Initialized     true
Sealed          false
Version         1.16.x
```

## Step 2: Read the Flag Directly

```bash
vault kv get secret/dojo/flag
```

Output:
```
=== Secret Path ===
secret/data/dojo/flag

====== Metadata ======
Key              Value
---              -----
created_time     2026-11-25T10:00:00Z
version          1

====== Data ======
Key      Value
---      -----
value    KUBE{vault_leases_expire_creds_dont}
hint     Dynamic credentials rotate automatically. Static ones do not.
```

**Flag: `KUBE{vault_leases_expire_creds_dont}`**

---

## Bonus: Understanding Dynamic Credentials

```bash
# Try to generate a dynamic DB credential
# (Will fail if no real PostgreSQL, but shows the concept)
vault read database/creds/app-role
```

If a real database were connected, you'd see:

```
Key                Value
---                -----
lease_id           database/creds/app-role/abc123XYZ
lease_duration     1m
lease_renewable    true
password           A1b2C3d4-random-pass
username           v-root-app-role-xK9pQ2mR4b-1234567890
```

```bash
# Record the lease_id
LEASE_ID=$(vault read -field=lease_id database/creds/app-role)

# Revoke it immediately (or wait 60 seconds for auto-expiry)
vault lease revoke $LEASE_ID
# Success! Revoked lease: database/creds/app-role/abc123XYZ

# Generate a new one — completely different username and password
vault read database/creds/app-role
# username: v-root-app-role-tP7cXj2nW8-9876543210  ← different!
# password: X9y8Z7w6-completely-different           ← different!
```

The key insight: if the first credential was stolen, it's already revoked. The attacker has nothing.

---

## Why This Matters

With static secrets:
- Attacker steals password → has permanent access until someone notices and rotates
- No way to know if the password was used by an attacker or a legitimate service

With Vault dynamic secrets:
- Attacker steals credential → it expires in 60 seconds to 1 hour
- Every credential use is logged (which pod, which SA, what time)
- Rotation is automatic — no human needed
