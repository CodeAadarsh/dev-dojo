# Type-Safe Endpoint

A code-review comment on a PR: *"None of these POST handlers actually validate the body. Price came in as a string from the mobile client yesterday and we silently stored `'9.99'` in the DB. Three downstream services interpreted it as NaN. Add Zod validation before we merge."*

Your job: implement the three route handlers in `src/app.ts` so the `node:test` harness passes end-to-end.

## Context

`setup.sh` plants a TypeScript + Fastify + Zod project:

```
~/.kube-dojo-work/01-type-safe-endpoint/
├── package.json          # fastify, zod, tsx (devDep)
├── tsconfig.json
├── src/
│   └── app.ts            # Fastify app — schema + store defined, handlers stubbed
└── test/
    └── sample.test.ts    # visible sample: one POST test you can run immediately
```

The Zod `ProductSchema`, the in-memory `store`, and the route registrations are already in place. Only the handler bodies need implementing.

## Prerequisites

```bash
cd ~/.kube-dojo-work/01-type-safe-endpoint
npm install
```

## Mission

Implement the three handler bodies in `src/app.ts`. The harness asserts exact HTTP semantics:

| Route | Condition | Required status |
|-------|-----------|-----------------|
| `POST /products` | valid body | **201** Created + full product in body |
| `POST /products` | missing `name` or `price` | **400** Bad Request |
| `POST /products` | `price` is negative or zero | **400** Bad Request |
| `POST /products` | `name` is empty string | **400** Bad Request |
| `GET /products/:id` | product exists | **200** OK + product in body |
| `GET /products/:id` | unknown id | **404** Not Found |
| `PUT /products/:id` | valid body, product exists | **200** OK + updated product |
| `PUT /products/:id` | unknown id | **404** Not Found |

Status codes are not optional. A 200 where 201 is required is a test failure.

## Why Zod over manual checks

`ProductSchema.safeParse(request.body)` returns `{ success: true, data: T }` or
`{ success: false, error: ZodError }` — never throws. The TypeScript type of `result.data`
is fully inferred: `typeof result.data === z.infer<typeof ProductSchema>`. You write the
schema once; both runtime validation and the TypeScript type come from the same source of truth.
Manual `if (!body.price || body.price < 0)` checks drift out of sync with types. The schema doesn't.

## Debugging the validation

**Symptom:** `POST` returns 500 instead of 400 on bad input.
**Cause:** The handler throws instead of sending an error reply. Fastify converts uncaught errors to 500, masking the validation failure.
**Fix:** Use `safeParse` (not `parse`). Check `!result.success` and `return reply.status(400).send(...)` before touching the store.

**Symptom:** `GET /products/:id` returns 200 with `null` body instead of 404.
**Cause:** `store.get(id)` returns `undefined` for a missing key, but the handler returns it anyway.
**Fix:** `if (!product) return reply.status(404).send({ error: 'Product not found' })` before the return. The `!` check covers both `undefined` and `null`.

**Symptom:** TypeScript error `Property 'id' does not exist on type 'string'` in the params handler.
**Cause:** Fastify's default `Params` type is `unknown`. The `app.get<{ Params: { id: string } }>` generic tells Fastify (and TypeScript) what to expect.
**Fix:** The generics are already in the stub — don't remove the `<{ Params: { id: string } }>` annotation.

> **War story.** A price validation bug caused a refund microservice at a previous project to issue £0 refunds for items whose price arrived as a string. The DB accepted it, downstream parsing silently coerced it to 0, and the billing system processed it. No 400, no error log — just £0 refunds for three hours during a flash sale. A single `z.number().positive()` in the order-intake endpoint would have caught it at the boundary. Schema validation at the HTTP boundary, not inside business logic, is the lesson.

## Verify

```bash
bash courses/course-33-node-backend-scale/challenges/01-type-safe-endpoint/verify.sh
```

All assertions green → flag printed.
