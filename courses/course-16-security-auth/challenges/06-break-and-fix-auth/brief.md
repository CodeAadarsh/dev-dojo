# Break and Fix: IDOR in an Order API

A teammate submits a PR. The description reads: *"Added auth — every endpoint now requires a valid token."* The code review looks fine: tokens are checked, users are resolved. The CI pipeline is green. You merge it.

Three days later a security researcher files a report: *"Authenticated as user B, I can retrieve user A's order data by guessing the order ID. Token verification is present but authorization is absent."*

This is OWASP A01:2021 — Broken Access Control. Authentication (are you who you say you are?) passed. Authorization (are you allowed to act on *this* object?) was never implemented.

## What you get

`setup.sh` plants a **deliberately vulnerable FastAPI app** in your work directory:

```
~/.kube-dojo-work/06-break-and-fix-auth/
├── app.py                    # vulnerable app — fix this
└── tests/
    ├── test_leak.py          # visible test that DEMONSTRATES the bug
    └── test_fix.py           # visible test that DEMONSTRATES the correct behaviour
```

`test_leak.py` passes on the vulnerable code (the leak is real). `test_fix.py` fails (the fix is not there yet). After your fix: `test_leak.py` should fail (the bug is gone) and `test_fix.py` should pass.

The verifier runs a hidden suite that checks both sides.

## Prerequisites

```bash
cd ~/.kube-dojo-work/06-break-and-fix-auth
python3 -m venv .venv && . .venv/bin/activate
pip install fastapi pytest httpx
```

## The vulnerability

`GET /orders/{order_id}` verifies the token, resolves the caller's identity, and returns the order. But it never checks whether `order_id` belongs to the caller. Any valid token grants access to every order in the system.

Run `test_leak.py` to see it in action:

```bash
cd ~/.kube-dojo-work/06-break-and-fix-auth
.venv/bin/pytest tests/test_leak.py -v
```

## Mission

Fix `app.py` so that:

1. **`GET /orders/{order_id}`** returns `200` when the authenticated user owns that order.
2. **`GET /orders/{order_id}`** returns `403 Forbidden` when the authenticated user does **not** own that order.
3. **`GET /orders/{order_id}`** still returns `404` when the order ID does not exist (do not change this behavior).
4. All other endpoints remain unmodified and functional.

> **Constraint:** do not restructure the authentication mechanism — `get_current_user()` and the `TOKENS` dict stay as-is. The fix is a single ownership check inside the endpoint body.

## Exact conditions the hidden verifier checks

| Caller | Order ID | Expected | Reason |
|--------|----------|----------|--------|
| alice (token-a) | 1 | 200 | alice owns order 1 |
| alice (token-a) | 2 | 403 | order 2 belongs to bob — IDOR blocked |
| bob (token-b) | 2 | 200 | bob owns order 2 |
| bob (token-b) | 1 | 403 | order 1 belongs to alice — IDOR blocked |
| alice (token-a) | 999 | 404 | order does not exist |
| no token | 1 | 401 | unauthenticated — unchanged |

## Why it matters

This bug class is so common that it has its own entry in every OWASP Top 10 since 2013. The fix is three lines. The cost of not fixing it — customer data exposure, regulatory fines, breach notification requirements — is orders of magnitude higher. The pattern to internalize: **every object-level endpoint must verify that the authenticated identity owns or is explicitly permitted to access the requested object.**

## Verify

```bash
bash courses/course-16-security-auth/challenges/06-break-and-fix-auth/verify.sh
```
