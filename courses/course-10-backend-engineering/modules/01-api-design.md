# API Design: REST, gRPC & Contracts

> **Module 01 · Course 10** — An API is a contract. The surface you design today gets called by mobile clients, partner integrations, and your own microservices for years. The decisions that look small — a 200 vs 202, a plural noun vs a verb, PUT vs PATCH — compound into either a robust, evolvable system or a minefield of breaking changes and client hacks.

You've shipped APIs. This module is about the decisions behind the decisions: why `PATCH /orders/{id}` is right, why `POST /getOrderStatus` is wrong, and how to make your error responses informative without leaking stack traces.

---

## Resource Modeling

REST's core rule: **resources are nouns, not verbs**. A resource is an entity or a collection, not an action.

| Wrong | Right | Why |
|-------|-------|-----|
| `POST /getUser` | `GET /users/{id}` | Verbs in the path break the uniform interface |
| `POST /createOrder` | `POST /orders` | Collection is the factory; HTTP method encodes the action |
| `POST /deleteUser` | `DELETE /users/{id}` | HTTP method is already a verb |
| `GET /getUserOrderHistory` | `GET /users/{id}/orders` | Ownership expressed as URL hierarchy |

Hierarchy depth rule of thumb: **no more than 2 levels deep** (`/users/{id}/orders`). If you need `/users/{id}/orders/{oid}/items/{iid}/reviews`, the hierarchy is leaking relational joins into the URL. At that depth, introduce a separate `/order-items/{iid}/reviews` resource or a query parameter.

### Sub-resources vs. query parameters

Use a **path segment** when the relationship is the primary identity of the resource:

```
GET /users/42/orders          # orders owned by user 42 — path is correct
GET /orders?userId=42         # equivalent, but user ownership is secondary to the listing
```

Use a **query parameter** for filters, sorts, and anything that doesn't change the resource's identity:

```
GET /orders?status=shipped&sort=createdAt:desc&userId=42
```

Not both — pick a canonical URL form and redirect the alternative with `301`.

---

## HTTP Verbs & Status Codes

### Verb semantics

| Verb | Safe? | Idempotent? | Has body? | Use for |
|------|-------|-------------|-----------|---------|
| GET | yes | yes | no | Read, never mutate |
| HEAD | yes | yes | no | Check existence/metadata without body |
| POST | no | **no** | yes | Create, or any non-idempotent action |
| PUT | no | yes | yes | Full-document replace (client supplies complete state) |
| PATCH | no | **no** (by default) | yes | Partial update |
| DELETE | no | yes | optional | Remove |
| OPTIONS | yes | yes | no | CORS preflight, capability discovery |

**Safe** = no server state change. **Idempotent** = repeating N times has the same effect as once.

GET is **always** safe. A `GET` that charges a card, deletes a row, or enqueues a job will be silently retried by browsers, CDNs, and HTTP clients — this is an actual production incident category.

### Status code discipline

Pick the most specific code; generic codes hide information from clients trying to handle errors programmatically.

```
2xx  →  success, distinguish:
  200 OK              — generic success with body
  201 Created         — POST that made a new resource; include Location header
  202 Accepted        — async job queued; include a polling URL in the body
  204 No Content      — successful DELETE or update with nothing to return
  206 Partial Content — range request (video streaming, large file chunk)

3xx  →  redirect:
  301 Moved Permanently — canonical URL change; clients cache this
  307 Temporary Redirect — same method must be used on redirect (safe for POST)
  308 Permanent Redirect — permanent, same method preserved

4xx  →  client is wrong:
  400 Bad Request     — payload failed validation
  401 Unauthorized    — not authenticated (the name is misleading)
  403 Forbidden       — authenticated but lacks permission
  404 Not Found       — resource does not exist (or you're hiding a 403)
  409 Conflict        — state machine violation (e.g. can't cancel a shipped order)
  410 Gone            — resource permanently deleted (strong cache hint)
  422 Unprocessable   — syntactically valid but semantically wrong (preferred over 400 for field validation)
  429 Too Many Requests — rate limited; include Retry-After header

5xx  →  server is wrong:
  500 Internal Server Error — catch-all; log it, don't expose internals
  502 Bad Gateway     — upstream service returned garbage
  503 Service Unavailable — intentional shedding; include Retry-After
  504 Gateway Timeout — upstream timed out
```

> **Return 409 for state machine violations, never 400.** If a client sends a valid `POST /orders/{id}/cancel` on an already-shipped order, the payload is structurally fine — the *state* is wrong. 409 tells the client to re-read the resource; 400 makes them think their code is broken.

---

## Idempotency

Distributed systems retry on timeout. If your `POST /payments` is not idempotent, a client that retries after a 504 charges the user twice. This is a real-money bug.

### Idempotency keys

The pattern: client generates a UUID (`uuid4()`), attaches it as a header (`Idempotency-Key: <uuid>`), and the server caches the response keyed to that value for a TTL (typically 24–48 hours).

```
Client → POST /payments
         Idempotency-Key: f3a91b2c-...
         { "amount": 5000, "currency": "INR" }

Server:
  1. Check idempotency store (Redis key: payments:<key>)
  2. If found → return the cached response verbatim (same status code, same body)
  3. If not found → process, store result, return
```

```python
from flask import request, jsonify
import redis, json

r = redis.Redis()

@app.route('/payments', methods=['POST'])
def create_payment():
    key = request.headers.get('Idempotency-Key')
    if key:
        cached = r.get(f'idem:{key}')
        if cached:
            return app.response_class(cached, status=200, mimetype='application/json')

    result = process_payment(request.json)
    response_data = json.dumps(result)

    if key:
        r.setex(f'idem:{key}', 86400, response_data)
    return app.response_class(response_data, status=201, mimetype='application/json')
```

### PUT is idempotent by contract

`PUT /users/42` with a full document must produce the same state no matter how many times it's sent. If your PUT doesn't guarantee this (e.g. it bumps a version counter on every call), that's a PATCH masquerading as a PUT.

### Making PATCH idempotent with conditional requests

PATCH is not inherently idempotent. Make it so with `ETag` + `If-Match`:

```
GET /orders/99          → response includes ETag: "abc123"
PATCH /orders/99
  If-Match: "abc123"    → server applies patch only if ETag matches current state
                        → 200 if ok; 412 Precondition Failed if state changed under you
```

---

## Pagination & Filtering

### Offset vs. cursor pagination

| Approach | Stable under inserts? | Efficient at depth? | Stateless? |
|----------|----------------------|---------------------|-----------|
| Offset (`?page=5&size=20`) | no — inserts shift everything | no — `OFFSET 10000` scans 10000 rows | yes |
| Cursor (`?after=eyJpZCI6MTAwfQ`) | yes | yes — `WHERE id > ? LIMIT 20` | yes |

Use **cursor/keyset** for any list that has high insert/delete rate, users scroll deep into, or you're paginating for an export.

```sql
-- Cursor pagination: encode {id, createdAt} in the cursor, decode on the server
SELECT id, title, created_at
FROM articles
WHERE created_at < :cursor_ts
   OR (created_at = :cursor_ts AND id < :cursor_id)
ORDER BY created_at DESC, id DESC
LIMIT 21;
-- Return 21 rows, check if you got 21 (there's a next page); encode row 20's position as the next cursor
```

### Filtering & sorting conventions

```
# exact match
GET /orders?status=pending
# range
GET /orders?createdAt[gte]=2025-01-01&createdAt[lt]=2025-02-01
# multiple values
GET /orders?status[]=pending&status[]=processing
# sort (field:direction, comma-separated for multi-sort)
GET /orders?sort=-createdAt,id
```

Always whitelist filterable/sortable fields; letting the client pass arbitrary column names is an injection risk.

---

## Versioning

| Strategy | Format | Pros | Cons |
|----------|--------|------|------|
| URI prefix | `/v1/users`, `/v2/users` | Immediately obvious, bookmarkable, cache-friendly | URL is "supposed to" identify the resource, not the API version |
| Accept header | `Accept: application/vnd.api.v2+json` | RESTfully correct | Harder to test in a browser; CDN/proxy rules are messier |
| Query param | `?version=2` | Easy to add | Considered bad practice; version is not a filter |

In practice, URI versioning wins for public APIs because developers can diff two versions in a browser tab. Header versioning makes sense for closed internal APIs where you control all clients.

### Breaking vs. non-breaking changes

**Non-breaking (safe without a new version):**
- Adding optional fields to a response
- Adding optional request parameters
- New endpoints
- Relaxing constraints (previously required field becomes optional)

**Breaking (require a new major version):**
- Removing or renaming a field
- Changing a field's type (`string` → `int`)
- Changing error codes for existing conditions
- Tightening constraints

Maintain v1 and v2 in parallel for a **sunset period** (6–12 months for public APIs). Announce via the `Sunset` response header:

```
Sunset: Sat, 01 Jan 2027 00:00:00 GMT
Deprecation: true
Link: <https://api.example.com/v2/migration-guide>; rel="successor-version"
```

---

## Error Shapes

A good error response is a contract. The [RFC 7807](https://datatracker.ietf.org/doc/html/rfc7807) "Problem Details" shape is standard enough to adopt:

```json
{
  "type": "https://api.example.com/errors/validation-failed",
  "title": "Request validation failed",
  "status": 422,
  "detail": "3 fields failed validation",
  "instance": "/v1/orders",
  "traceId": "4f3a92b1-e3c0-4d2f-9b5e-8a1c7d2e0f3a",
  "errors": [
    { "field": "amount",   "code": "MUST_BE_POSITIVE",    "message": "amount must be > 0" },
    { "field": "currency", "code": "UNSUPPORTED_CURRENCY", "message": "currency must be INR, USD, or EUR" }
  ]
}
```

Rules:
1. `type` is a stable URI — clients can `switch` on it without string-matching `title`.
2. `traceId` links to your observability system (OpenTelemetry span ID, Loki trace ID).
3. Never include stack traces, SQL, or internal paths in 4xx/5xx responses.
4. `errors` array is machine-readable — client-side forms need field-level messages, not a single paragraph.

---

## REST vs gRPC vs GraphQL

```
┌────────────────┬────────────────────┬────────────────────┬───────────────────┐
│                │ REST               │ gRPC               │ GraphQL           │
├────────────────┼────────────────────┼────────────────────┼───────────────────┤
│ Transport      │ HTTP/1.1 (usually) │ HTTP/2 (required)  │ HTTP/1.1 or 2     │
│ Format         │ JSON (typically)   │ Protobuf (binary)  │ JSON              │
│ Schema         │ OpenAPI (opt-in)   │ .proto (required)  │ SDL (required)    │
│ Streaming      │ SSE/WebSocket      │ native             │ subscriptions     │
│ Typing         │ loose (JSON)       │ strong (proto)     │ strong (SDL)      │
│ Code gen       │ optional           │ automatic          │ optional          │
│ Browser native │ yes                │ grpc-web proxy     │ yes               │
│ Best for       │ public APIs        │ internal services  │ flexible frontends│
└────────────────┴────────────────────┴────────────────────┴───────────────────┘
```

### When gRPC wins

- Tight internal service-to-service calls: binary Protobuf is ~3–10x smaller and faster to decode than JSON for numeric or repeated fields.
- Bidirectional streaming (a live metrics feed, a file upload with progress).
- You want generated client stubs that compile-check the contract — no more hand-crafting HTTP clients.

```protobuf
// orders.proto
syntax = "proto3";
package orders.v1;

service OrderService {
  rpc CreateOrder (CreateOrderRequest) returns (Order);
  rpc StreamOrderEvents (OrderEventsRequest) returns (stream OrderEvent);
}

message CreateOrderRequest {
  string user_id = 1;
  repeated OrderItem items = 2;
  string idempotency_key = 3;
}

message Order {
  string id = 1;
  string status = 2;
  int64 total_paise = 3;
  string created_at = 4;
}
```

### When GraphQL wins

- A backend-for-frontend (BFF) layer where multiple UI teams fetch exactly the fields they need.
- Aggregating data from 3+ microservices without writing N endpoint combinations.
- Rapid UI iteration — frontend changes what it fetches without a backend deploy.

GraphQL is **not** a replacement for gRPC between services — the query flexibility is for consumers, not for inter-service chatter.

---

## OpenAPI

OpenAPI 3.1 is the specification format for REST APIs. Write the spec **before** the implementation (design-first), or generate it from code annotations and treat it as the canonical reference.

```yaml
openapi: "3.1.0"
info:
  title: Order Service API
  version: "1.0.0"
paths:
  /orders:
    post:
      operationId: createOrder
      summary: Create a new order
      requestBody:
        required: true
        content:
          application/json:
            schema:
              $ref: '#/components/schemas/CreateOrderRequest'
      responses:
        "201":
          description: Order created
          headers:
            Location:
              schema:
                type: string
              description: URL of the created order
          content:
            application/json:
              schema:
                $ref: '#/components/schemas/Order'
        "422":
          $ref: '#/components/responses/ValidationError'
        "429":
          $ref: '#/components/responses/RateLimited'
components:
  schemas:
    CreateOrderRequest:
      type: object
      required: [userId, items]
      properties:
        userId:
          type: string
          format: uuid
        items:
          type: array
          minItems: 1
          items:
            $ref: '#/components/schemas/OrderItem'
        idempotencyKey:
          type: string
          format: uuid
    Order:
      type: object
      properties:
        id:
          type: string
        status:
          type: string
          enum: [pending, processing, shipped, cancelled]
        totalPaise:
          type: integer
```

Use `$ref` liberally — a schema defined once in `components` is the single source of truth for both request validation and response documentation. FastAPI and Hono auto-generate OpenAPI from type annotations; Express needs tsoa or zod-to-openapi.

---

## Debugging API Design

The three API bugs that cause the most real-world pain: wrong status codes confusing client retry logic, N+1 requests amplifying DB load, and breaking changes silently wrecking integrations.

### Symptom → Cause → Fix

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Client retries non-retriable errors (re-submitting a payment after a DB unique-key violation) | Server returns 500 for a 400-class error (duplicate key, constraint fail) | Return 409 instead; HTTP clients retry 5xx by default, not 4xx |
| Client polls GET in a tight loop after a POST | Server returns 200 with `"status":"processing"` in body instead of 202 + `Location` | Return 202 Accepted with a polling URL in the body |
| Mobile app breaks on a new backend deploy | Breaking field rename/removal without a version bump | Follow non-breaking change rules; maintain old field as a deprecated alias with a `Deprecation` header |
| CDN caches a 401 and serves it to authenticated users | Missing `Cache-Control: no-store` on auth-gated responses | Always emit `Cache-Control: no-store` on anything requiring auth |
| Frontend makes N separate API calls to render a list | REST endpoint returns only IDs, not expanded objects | Expand via `?include=items` query param, or introduce a GraphQL BFF |
| OpenAPI spec disagrees with actual behavior | Spec maintained manually, drifts from code | Generate spec from code annotations |

### Diagnosing wrong status codes

```bash
# See what status codes your service returns across log files
grep -oP '"status":\s*\K[0-9]+' /var/log/app/access.log | sort | uniq -c | sort -rn

# Full HTTP exchange for a single request
curl -v -X POST https://api.example.com/v1/payments \
  -H 'Content-Type: application/json' \
  -H 'Idempotency-Key: test-key-001' \
  -d '{"amount": 100, "currency": "INR"}'

# Confirm idempotency: re-run with the same key; should return identical response + 200
curl -sv -X POST https://api.example.com/v1/payments \
  -H 'Idempotency-Key: test-key-001' \
  -d '{"amount": 100, "currency": "INR"}' 2>&1 | grep -E '^[<>]'
```

### Diagnosing N+1 over HTTP

The HTTP equivalent of the ORM N+1: a BFF or client makes one call to get a list, then N calls to hydrate each item.

```javascript
// Add a global axios interceptor in dev/test to surface all outbound requests
axios.interceptors.request.use(config => {
  console.log(`HTTP ${config.method?.toUpperCase()} ${config.url}`);
  return config;
});
// Run a single page load; look for repeated "GET /products/1", "GET /products/2" patterns
```

Fix with a batch endpoint:

```
# Before: N round-trips
GET /products/1   GET /products/2  ... GET /products/N

# After: one round-trip
GET /products?ids=1,2,3,...,N
# or POST /products/batch if the ID list exceeds URL length limits (~2000 chars)
```

### Catching breaking changes before deploy

```bash
# Diff your OpenAPI spec against the previous version with oasdiff
npx @oasdiff/oasdiff diff old-spec.yaml new-spec.yaml --format text

# Flag breaking changes only
npx @oasdiff/oasdiff breaking old-spec.yaml new-spec.yaml

# In CI: fail the build if breaking changes are detected
npx @oasdiff/oasdiff breaking old-spec.yaml new-spec.yaml && echo "no breaking changes" || exit 1
```

> **War story.** We shipped a "non-breaking" change at SAP: an optional `metadata` field added to every response on the billing API. Three months later, a partner integration started returning 400s. Their code deserialized our response into a strict struct with `unknown fields = error`. Adding a field is *breaking* for strict deserializers, even though it's additive in JSON Schema terms. We had to add `?includeMetadata=false` as a permanent compat parameter. The lesson: non-breaking in OpenAPI terms is still breaking for clients with strict parsing. Document your deserialization contract, not just your schema.

---

## Checkpoint

You're ready for the challenges when you can, without looking anything up:

1. Name the five cases where you'd use 201, 202, 204, 409, and 422 respectively.
2. Explain in one sentence why `GET` must never mutate state.
3. Implement idempotency on a `POST /payments` endpoint using a Redis-backed idempotency key.
4. Choose between cursor and offset pagination for a high-insert event log and justify it with a SQL example.
5. List three changes that are breaking in practice even if OpenAPI considers them additive.
6. Decide whether to use REST, gRPC, or GraphQL for: (a) a public payments API, (b) a log-streaming microservice, (c) a BFF feeding four mobile screens with different data shapes.
7. Write a `PATCH /orders/{id}` handler that returns 412 when the `If-Match` ETag doesn't match.
8. Describe the `Sunset` header pattern and when to emit it.

➡ Next up: **Data Modeling & Databases** — where we trade URL shapes for B-tree internals, isolation levels, and the question every senior gets wrong on system design interviews.
