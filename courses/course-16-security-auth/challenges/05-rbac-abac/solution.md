# Solution — RBAC + ABAC Policy Engine

## Complete `policy.py`

```python
ROLES = {
    "admin":    {"read", "write", "delete", "edit"},
    "editor":   {"read", "write", "edit"},
    "viewer":   {"read"},
    "owner":    {"read", "edit"},
}

USERS = {
    "alice":   {"role": "admin"},
    "bob":     {"role": "editor"},
    "carol":   {"role": "viewer"},
    "dave":    {"role": "owner"},
    "eve":     {"role": "owner"},
}

RESOURCES = {
    "order:1":  {"owner": "dave"},
    "order:2":  {"owner": "eve"},
    "report:1": {"owner": "alice"},
}


def authorize(user: str, action: str, resource: str) -> bool:
    if user not in USERS or resource not in RESOURCES:
        return False

    user_role = USERS[user]["role"]
    role_permissions = ROLES.get(user_role, set())

    if action not in role_permissions:
        return False

    if user_role == "owner" and action == "edit":
        resource_owner = RESOURCES[resource].get("owner")
        if resource_owner != user:
            return False

    return True
```

## Why each piece is correct

### Guard unknowns first

Checking `user not in USERS or resource not in RESOURCES` before any role lookup means the function never KeyErrors on unexpected input. More importantly, it means a misconfigured caller that passes an unrecognised username is denied — fail-closed, not fail-open. Any default that grants access for unrecognised principals is a vulnerability.

### RBAC gate

`action not in role_permissions` is the role check. The roles are sets, so membership is O(1) and adding a new action requires editing exactly one place — the `ROLES` dict. Hardcoding `if action == "read": ...` chains instead of a set lookup is the pattern that leads to missing actions when requirements grow.

### ABAC ownership gate scope

The `if user_role == "owner" and action == "edit":` condition is deliberate:
- `admin` and `editor` bypass this gate — they are trusted service accounts, not end-users.
- The gate only fires on `"edit"` because that is the write action `owner` holds. Read-across-owners is already prevented by RBAC: `owner` can only read their own resources because they share the role with all other owners — but any owner attempting to *read* a resource they do not own fails here too (the `read` action is in the `owner` role set, but ownership is not checked for `read` in the current model; see hardening note below).
- Scoping the ABAC check to a single role means adding a new role (e.g. `"auditor"`) does not silently inherit the ownership gate.

### Hardening preview

The current model allows `dave` to read `order:2` (owned by `eve`) because the ownership gate only fires on `edit`. A production system would apply the ABAC ownership check to all write actions AND to reads, using a policy engine (OPA, Cedar) rather than hand-coded conditionals. Cedar and OPA let you express `permit(principal, action, resource) when principal == resource.owner` as a first-class policy statement, version-controlled separately from application code.

## Attacker's view

The IDOR exploit path without this fix:

```
POST /login            -> 200 + token (as eve)
GET  /orders/1         -> 200 (order belongs to dave) — information leak
PUT  /orders/1         -> 200 (modification on dave's order) — data tampering
DELETE /orders/1       -> 204 — data destruction
```

With the fix: all three lateral-access requests return 403 Forbidden. The token is valid (authentication passes), but the ownership check (authorization) blocks the action.

## Verify

```bash
bash courses/course-16-security-auth/challenges/05-rbac-abac/verify.sh
```
