# Solution — Break and Fix: IDOR in an Order API

## The fix — three lines in `app.py`

Add an ownership check inside `get_order()`:

```python
@app.get("/orders/{order_id}")
def get_order(order_id: int, current_user: str = Depends(get_current_user)):
    order = ORDERS.get(order_id)
    if order is None:
        raise HTTPException(status_code=404, detail="Order not found")
    if order["owner"] != current_user:                        # ← add this
        raise HTTPException(status_code=403, detail="Forbidden")  # ← and this
    return {"order_id": order_id, **order}
```

The 404 check stays before the 403 check. Order matters:

- **404 first**: reveals to the caller that no such order exists — this is generally acceptable for authenticated users (the order ID space is not secret). Some systems prefer always returning 403 for both "does not exist" and "you don't own it" to prevent enumeration; if that's your threat model, return 403 first. The verifier accepts the 404-first ordering.
- **403 second**: tells the authenticated caller their credentials are valid but they are not permitted to act on *this* resource. Do not return 404 here — that would let an attacker silently confirm that order 42 exists (because you'd get 200 on your own order and 404 on others).

## Why this is IDOR

IDOR (Insecure Direct Object Reference) is a sub-class of broken access control. The name comes from the mechanism: the client passes a *direct reference* to an object (the integer order ID), and the server honours it without verifying the client's relationship to that object.

The three-line fix is always the same structural pattern:

```
resolve the object
check object.owner == caller (or equivalent permission check)
proceed only if check passes
```

Every resource type that carries identity (orders, invoices, messages, documents, user profiles) needs this check on every endpoint that retrieves, modifies, or deletes it.

## Attacker's view — before the fix

```bash
# authenticate as bob
curl -s -X GET http://localhost:8000/orders/1 \
     -H "Authorization: Bearer token-b"
# -> 200 {"order_id": 1, "owner": "alice", "item": "Laptop"}

# enumerate all orders by ID
for i in $(seq 1 100); do
  curl -s http://localhost:8000/orders/$i \
       -H "Authorization: Bearer token-b" | grep -q "owner" && echo "order $i exists"
done
```

## Attacker's view — after the fix

```bash
curl -s http://localhost:8000/orders/1 -H "Authorization: Bearer token-b"
# -> 403 {"detail":"Forbidden"}
```

The attacker knows they are authenticated (401 would indicate otherwise) but cannot access the resource. The ownership check is the only change.

## Hardening preview

The three-line fix works in a monolith with an in-process data store. In a microservices architecture where the Auth service and the Order service are separate processes, the authorization check needs to happen at the service boundary — either via a middleware that forwards the token and the resource owner together to a policy service (OPA, Cedar), or via a gateway-level policy. The pattern is identical; the enforcement point moves.

## Verify

```bash
bash courses/course-16-security-auth/challenges/06-break-and-fix-auth/verify.sh
```
