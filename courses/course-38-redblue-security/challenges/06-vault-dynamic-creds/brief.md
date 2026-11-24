# Vault Dynamic Credentials

Static secrets are a liability. If a database password is hardcoded in a Kubernetes Secret, it lives forever — until someone rotates it, which almost never happens. HashiCorp Vault solves this with **dynamic secrets**: short-lived credentials generated on demand, automatically expired.

In this challenge, you'll work with a Vault instance to generate a dynamic PostgreSQL credential, use it, and understand why the TTL model is fundamentally better than static secrets.

## Background

```
Traditional approach (dangerous):
  DB_PASSWORD=hunter2  →  Kubernetes Secret  →  Pod mounts it  →  Never rotated
  If hunter2 leaks: attacker has access FOREVER

Vault dynamic secrets approach (secure):
  App needs DB access
       ↓
  App calls Vault: GET /v1/database/creds/app-role
       ↓
  Vault generates: username=v-app-xyz123, password=A1b2C3d4...
  TTL: 1 hour (auto-expires)
       ↓
  App uses credentials for 1 hour
       ↓
  Credentials expire (Vault revokes them in the DB)
  If leaked: expired after 1 hour, automatically
```

## The Vault Token Flow

```
                 ┌───────────────────────────────┐
                 │          HashiCorp Vault        │
                 │                                 │
  App Pod        │  Auth: Kubernetes JWT Auth      │
  ───────────    │  ┌──────────────────────────┐   │
  SA Token  ────►│  │  Token from k8s SA JWT   │   │
                 │  └──────────────┬───────────┘   │
                 │                 │ authenticates  │
                 │                 ▼               │
                 │  Policy: allow db/creds/app-role │
                 │                 │               │
                 │                 ▼               │
                 │  DB Secrets Engine              │
                 │  → generates username+password  │
                 │  → TTL: 1h                      │
                 └───────────────────────────────-─┘
```

## Mission

1. Connect to the dev Vault instance running in namespace `dojo-sec-vault`
2. Authenticate using the root token (dev mode — in production you'd use K8s auth)
3. Enable the KV secrets engine
4. Write a secret at `secret/dojo/challenge`
5. Read the secret — it contains the flag

## Production Context

This challenge uses Vault in dev mode (no persistence, root token pre-set) to focus on the workflow. In production:
- Vault runs in HA mode with Raft storage
- Authentication is via Kubernetes JWT auth (pod SA token → Vault token → secrets)
- Dynamic database secrets are generated per-request with 1h TTL
- All access is audited to a log
