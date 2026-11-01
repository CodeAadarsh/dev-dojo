# Dynamic Secrets Rotation

An on-call escalation note from last quarter:

> "We rotated the DB password in the Secrets Manager but the old password is still valid. Three services haven't restarted yet — they're still connecting with the old cred. We're blocking the incident because we can't tell which connections are stale."

This is the **static secret problem**. A password that lives for 90 days is valid for 90 days. If it leaks — via a log, a screenshot, a compromised CI pipeline — it keeps working until someone notices.

HashiCorp Vault's database engine solves this with **dynamic secrets**:

1. An app calls `vault read database/creds/my-role`.
2. Vault creates a **unique** DB user with a **lease** (TTL, e.g., 1 hour).
3. When the TTL expires, Vault automatically drops the DB user.
4. When the app restarts or redeploys, it calls Vault again — new unique user, new TTL.
5. If a credential leaks, Vault's `vault lease revoke <lease_id>` drops the user immediately.

The on-call problem above disappears: there is no "old password" — each credential has a finite, tracked lifetime.

## Prerequisites

```bash
pip install pytest
```

No external services needed. This challenge simulates Vault's credential backend in pure Python.

## What `setup.sh` plants

```
~/.kube-dojo-work/02-dynamic-secrets-rotation/
├── credential_backend.py    # CredentialBackend class with stubbed methods
└── tests/
    ├── __init__.py
    └── test_visible.py      # smoke tests you can run locally
```

## Mission

Implement the five methods of `CredentialBackend` in `credential_backend.py`:

| Method | Contract |
|--------|----------|
| `issue(ttl_seconds)` | Create a unique credential + lease. Return `{lease_id, username, password, expires_at}`. |
| `validate(lease_id)` | Return `True` iff the lease exists, is not expired, and is not revoked. |
| `revoke(lease_id)` | Immediately invalidate the lease. Raise if lease unknown. |
| `rotate(lease_id)` | Issue a new credential, revoke the old one atomically. Return new credential. |
| `cleanup_expired(ttl_seconds)` | Remove all past-TTL leases. Return the count removed. |

The verify script runs a hidden test suite that asserts:

- Issued credential validates immediately
- A credential with a 50 ms TTL is invalid after 100 ms
- A revoked credential is immediately invalid
- Revoking an unknown lease raises an exception
- `rotate` returns a new credential AND the old one is simultaneously invalid
- Two `issue` calls return distinct `lease_id` / credentials
- `cleanup_expired` removes exactly the expired leases and leaves valid ones untouched

## Local test run

```bash
cd ~/.kube-dojo-work/02-dynamic-secrets-rotation
python3 -m venv .venv && . .venv/bin/activate
pip install pytest
pytest tests/ -v
```

## Verify

```bash
bash courses/course-31-secrets-zero-trust/challenges/02-dynamic-secrets-rotation/verify.sh
```

## The Vault parallel

| This challenge | Vault equivalent |
|---------------|-----------------|
| `issue(ttl)` | `vault read database/creds/my-role` |
| `validate(lease_id)` | checking lease status via `vault lease lookup` |
| `revoke(lease_id)` | `vault lease revoke <lease_id>` |
| `rotate(lease_id)` | deploy cycle: issue new → old TTL expires (or manual revoke) |
| `cleanup_expired()` | Vault's internal lease expiry daemon |

In production the `username` maps to a real DB user Vault creates via the database plugin, and `password` is a random string Vault generates and never stores. This challenge uses the same shape with an in-memory store.
