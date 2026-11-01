# Solution — Type-Safe Endpoint

Complete `src/app.ts`. Key decisions explained after the code.

```typescript
import Fastify from 'fastify'
import { z } from 'zod'

export const app = Fastify({ logger: false })

const ProductSchema = z.object({
  name: z.string().min(1),
  price: z.number().positive(),
  category: z.string().optional(),
})

export type Product = z.infer<typeof ProductSchema> & { id: number }

const store = new Map<number, Product>()
let nextId = 1

app.post('/products', async (request, reply) => {
  const result = ProductSchema.safeParse(request.body)
  if (!result.success) {
    return reply.status(400).send({ error: 'Validation failed', issues: result.error.issues })
  }
  const product: Product = { ...result.data, id: nextId++ }
  store.set(product.id, product)
  return reply.status(201).send(product)
})

app.get<{ Params: { id: string } }>('/products/:id', async (request, reply) => {
  const id = parseInt(request.params.id, 10)
  const product = store.get(id)
  if (!product) {
    return reply.status(404).send({ error: 'Product not found' })
  }
  return reply.send(product)
})

app.put<{ Params: { id: string } }>('/products/:id', async (request, reply) => {
  const id = parseInt(request.params.id, 10)
  if (!store.has(id)) {
    return reply.status(404).send({ error: 'Product not found' })
  }
  const result = ProductSchema.safeParse(request.body)
  if (!result.success) {
    return reply.status(400).send({ error: 'Validation failed', issues: result.error.issues })
  }
  const product: Product = { ...result.data, id }
  store.set(id, product)
  return reply.send(product)
})
```

## Why each piece is required

**`safeParse` not `parse`.**
`ProductSchema.parse(body)` throws a `ZodError` on invalid input. Inside a Fastify async handler, that uncaught throw becomes a 500. `safeParse` returns a discriminated union instead — check `result.success` and send your own 400 with `result.error.issues` for structured error details.

**`reply.status(201).send(product)` on POST.**
Fastify's default status for every route is 200. The 201 tells the client a resource was created. Unlike FastAPI's decorator-level `status_code=`, in Fastify you call `reply.status(...)` on the response object. The `return` before `reply.status(...).send(...)` ensures the handler exits after sending — without it, Fastify warns about "reply already sent."

**`!store.has(id)` before the PUT body parse.**
Check existence first, then validate. If you validate first and the product doesn't exist, you'd send a 400 for a body that would have been valid. Existence is a precondition; input validity is a postcondition. Check preconditions first so the error message is accurate.

**`id` preserved on PUT.**
`{ ...result.data, id }` spreads the validated body fields then overwrites `id` with the path parameter. This prevents a malicious/mistaken body from changing the product's id. The id in the URL is authoritative.

**`app.get<{ Params: { id: string } }>`.**
Fastify's generic lets TypeScript know the shape of `request.params`. Without it, `request.params.id` is typed as `unknown` and TypeScript rejects `parseInt(request.params.id, 10)`. The route param always arrives as a string — `parseInt` converts it.

## Zod type inference — the real value

```typescript
// These two types are always in sync — no drift possible:
const ProductSchema = z.object({ name: z.string().min(1), price: z.number().positive() })
type Product = z.infer<typeof ProductSchema>  // { name: string; price: number }
```

If you add a field to `ProductSchema`, the TypeScript type updates automatically. If you remove a field, TypeScript catches every place the field was used. This is the pattern to replicate for every request/response boundary in a production service.

## Apply and verify

```bash
# Replace src/app.ts with the solution above, then:
cd ~/.kube-dojo-work/01-type-safe-endpoint
npm test
bash courses/course-33-node-backend-scale/challenges/01-type-safe-endpoint/verify.sh
```
