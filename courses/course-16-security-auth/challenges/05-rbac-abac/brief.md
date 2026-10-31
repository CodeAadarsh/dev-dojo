# RBAC + ABAC Policy Engine

During a security review of your order management service, the reviewer writes: *"The API checks roles but not ownership. An authenticated customer can PUT `/orders/42` even if order 42 belongs to a different customer. Role-based checks are necessary but not sufficient — you need attribute-based rules too."*

## The two authorization models — and why you need both

**RBAC (Role-Based Access Control)** maps users to roles and roles to permitted actions. It is simple to audit and manage: an `admin` can do everything; a `readonly` user can only read. But RBAC is blind to *which* object is being acted on. Two customers in the same role are indistinguishable to a pure RBAC check.

**ABAC (Attribute-Based Access Control)** evaluates attributes of the subject (user), the action, and the resource together. The ownership rule — "a user can edit a resource only if they own it" — is a pure ABAC rule. It cannot be expressed in RBAC alone without creating one role per user, which is absurd.

The combination: RBAC gates *what actions a role can perform*; ABAC gates *which specific objects those actions are permitted on*. Together they prevent the classic IDOR (Insecure Direct Object Reference) bug: a user who knows order ID 42 can't act on it just because they're authenticated.

## Work directory layout

`setup.sh` plants a skeleton in your work directory:

```
~/.kube-dojo-work/05-rbac-abac/
├── policy.py                  # implement authorize() here
└── tests/
    └── test_policy_sample.py  # visible sample tests
```

## Prerequisites

```bash
cd ~/.kube-dojo-work/05-rbac-abac
python3 -m venv .venv && . .venv/bin/activate
pip install pytest
```

## Data model (already defined in skeleton)

```python
ROLES = {
    "admin":    {"read", "write", "delete", "edit"},
    "editor":   {"read", "write", "edit"},
    "viewer":   {"read"},
    "owner":    {"read", "edit"},   # only on own resources
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
```

## Mission

Implement `authorize(user: str, action: str, resource: str) -> bool` in `policy.py`.

The rules, in evaluation order:

1. **Unknown user or resource** → `False`.
2. **RBAC**: if the user's role does not include `action` in its permission set → `False`.
3. **ABAC ownership gate** (applies when the action is `"edit"`): if the resource has an `owner` attribute, the user must be that owner → `False` otherwise.
4. All checks pass → `True`.

### Decision matrix the hidden verifier asserts

| User | Action | Resource | Expected | Reason |
|------|--------|----------|----------|--------|
| alice | read | order:1 | True | admin has read |
| alice | delete | order:1 | True | admin has delete |
| bob | write | order:1 | True | editor has write |
| bob | edit | order:1 | True | editor has edit + no ownership rule blocks editors |
| carol | read | report:1 | True | viewer has read |
| carol | write | order:1 | False | viewer lacks write |
| carol | delete | order:1 | False | viewer lacks delete |
| dave | read | order:1 | True | owner has read + own resource |
| dave | edit | order:1 | True | owner has edit + own resource (ABAC passes) |
| dave | edit | order:2 | False | owner has edit but ABAC blocks — order:2 belongs to eve |
| eve | edit | order:2 | True | owner + own resource |
| eve | edit | order:1 | False | IDOR attempt — order:1 belongs to dave |
| bob | edit | report:1 | True | editor has edit; editors bypass the ownership rule |
| unknown | read | order:1 | False | unknown user |
| dave | read | order:999 | False | unknown resource |

> The ownership ABAC rule applies to the `"owner"` role only. Users in `editor`, `admin`, or `viewer` are not subject to the ownership gate — their RBAC grants stand independently. This models a common real-world pattern: `admin` and `editor` are trusted ops/staff accounts; `owner` is the end-customer role that is scoped to their own data.

## Why this matters

The IDOR vulnerability class is in the OWASP Top 10 (A01 — Broken Access Control) every year it is published. It is not a crypto bug or a subtle race condition; it is a missing three-line check. The reason it persists is that authentication ("are you logged in?") and authorization ("are you allowed to act on *this* object?") are consistently conflated. This challenge hard-codes the distinction.

## Verify

```bash
bash courses/course-16-security-auth/challenges/05-rbac-abac/verify.sh
```
