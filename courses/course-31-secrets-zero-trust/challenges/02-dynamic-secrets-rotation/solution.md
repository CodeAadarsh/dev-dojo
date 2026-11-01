# Solution — Dynamic Secrets Rotation

Complete `credential_backend.py` implementation.

```python
import time
import uuid
import secrets
from dataclasses import dataclass
from typing import Dict


@dataclass
class Lease:
    lease_id: str
    username: str
    password: str
    expires_at: float
    revoked: bool = False


class CredentialBackend:
    def __init__(self):
        self._leases: Dict[str, Lease] = {}

    def issue(self, ttl_seconds: float) -> dict:
        lease_id = str(uuid.uuid4())
        username = f"dojo-{secrets.token_hex(6)}"
        password = secrets.token_urlsafe(24)
        expires_at = time.time() + ttl_seconds
        self._leases[lease_id] = Lease(
            lease_id=lease_id,
            username=username,
            password=password,
            expires_at=expires_at,
        )
        return {
            "lease_id": lease_id,
            "username": username,
            "password": password,
            "expires_at": expires_at,
        }

    def validate(self, lease_id: str) -> bool:
        lease = self._leases.get(lease_id)
        if lease is None:
            return False
        if lease.revoked:
            return False
        if time.time() > lease.expires_at:
            return False
        return True

    def revoke(self, lease_id: str) -> None:
        if lease_id not in self._leases:
            raise KeyError(f"unknown lease: {lease_id}")
        self._leases[lease_id].revoked = True

    def rotate(self, lease_id: str) -> dict:
        if not self.validate(lease_id):
            raise ValueError(f"lease {lease_id!r} is not valid — cannot rotate")
        remaining_ttl = self._leases[lease_id].expires_at - time.time()
        new_ttl = max(remaining_ttl, 60.0)
        new_cred = self.issue(new_ttl)
        self.revoke(lease_id)
        return new_cred

    def cleanup_expired(self) -> int:
        now = time.time()
        expired_ids = [
            lid for lid, lease in self._leases.items()
            if now > lease.expires_at
        ]
        for lid in expired_ids:
            del self._leases[lid]
        return len(expired_ids)
```

## Why each piece is required

**`uuid.uuid4()` for `lease_id`.**
UUIDs are collision-resistant at any reasonable scale and carry no information about ordering or count — an attacker can't enumerate leases by guessing sequential IDs. Vault uses a similar opaque token format.

**`secrets.token_hex` / `secrets.token_urlsafe` for username and password.**
`secrets` is the stdlib module for cryptographically secure random strings — it uses `os.urandom` internally. Do not use `random` for credentials; `random` is deterministic given its seed and can be predicted.

**Three-condition check in `validate`.**
The order matters: check existence first (avoids a `KeyError`), then revoke (intentional invalidation), then TTL (natural expiry). A revoked lease that hasn't expired yet must still be invalid — `revoked=True` takes precedence.

**Atomic rotate: issue first, then revoke.**
Issuing first ensures the new credential is in the store before we kill the old one. If the order were reversed and something panicked between revoke and issue, the caller would have no credential. This is the same reason Vault issues a new token before revoking the old one during token renewal.

**`cleanup_expired` removes by TTL, not by revoke status.**
A revoked but not-yet-expired lease is already logically invalid (validate returns False). Removing it early would cause `validate` to return False for a different reason (missing vs. revoked) — this inconsistency can mask bugs. Clean up based purely on the TTL clock.

## Vault parallel

In production, `issue` calls the database plugin: `CREATE USER ... WITH PASSWORD ... VALID UNTIL NOW() + INTERVAL '1 hour'`. The lease tracks the DB username so that on expiry Vault can `DROP USER`. The credential store (`_leases`) maps to Vault's barrier storage. Everything else is the same contract.

## Attacker's view

Dynamic secrets limit the blast radius of a credential leak. A static DB password leaked to a log file gives an attacker indefinite access. A dynamic credential leaked the same way is valid for at most the TTL (e.g., 1 hour) — and if the platform supports credential revocation (it does), you can invalidate it the moment the leak is detected.

## Verify

```bash
cd ~/.kube-dojo-work/02-dynamic-secrets-rotation
. .venv/bin/activate
pytest tests/ -v
bash courses/course-31-secrets-zero-trust/challenges/02-dynamic-secrets-rotation/verify.sh
```
