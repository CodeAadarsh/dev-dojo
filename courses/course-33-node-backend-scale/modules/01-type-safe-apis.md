# Type-Safe API Design

> **Module 01 · Course 33** — TypeScript's type checker runs at compile time, then evaporates. By the time your server handles a live request, every annotation is gone. This module is about closing the gap: using a single schema to generate both compile-time types and runtime validation, so a typo in a request body gets caught at the boundary — not in a `TypeError` three call-frames deep at 2 am.

You already write TypeScript. This is fast on "add `: string`" and slow on the parts that matter most for a backend: where the type system ends and what you do there instead.

---

## The compile-time / runtime split

TypeScript types are completely erased during compilation. The compiled JavaScript has no memory of them.

```ts
// TypeScript source
function greet(name: string): string {
  return `Hello, ${name}`;
}

// After tsc — the type annotation is gone
function greet(name) {
  return `Hello, ${name}`;
}
```

For a web server, this means anything that crosses a process boundary is `unknown` at runtime — regardless of what you declared. You can cast it:

```ts
const body = req.body as CreateUserInput; // TypeScript trusts you
console.log(body.email.toLowerCase());    // runtime TypeError if email is missing
```

The cast silences the compiler. Node.js is not silenced. The fix is not more TypeScript — it is **runtime validation at the entry point**, before any code touches the data.

```
┌─────────────────────────────────────────────────────────────────────┐
│               What TypeScript can and cannot enforce                │
│                                                                     │
│  COMPILE-TIME SAFE ZONE (TypeScript checks this)                    │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │  internal function calls · service layer · module APIs       │   │
│  │  database query builders · anything that stays in-process    │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                           ▲                                         │
│             parse here — the validated data enters the safe zone    │
│                           │                                         │
│  RUNTIME BOUNDARY (only runtime validation protects this)           │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │  HTTP request body/params/headers · env vars                 │   │
│  │  JSON.parse() results · database rows · external API calls   │   │
│  │  WebSocket messages · queue job payloads · file contents     │   │
│  └──────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Zod: one schema, two guarantees

[Zod](https://zod.dev) lets you define a shape once and derive both the runtime validator and the TypeScript type from it. The type is never manually declared — it is inferred:

```ts
import { z } from 'zod';

const CreateUserSchema = z.object({
  email: z.string().email(),
  name: z.string().min(1).max(100),
  role: z.enum(['admin', 'editor', 'viewer']).default('viewer'),
  age: z.number().int().positive().optional(),
});

// The TypeScript type is inferred — no separate interface needed
type CreateUserInput = z.infer<typeof CreateUserSchema>;
/*
  {
    email: string;
    name: string;
    role: "admin" | "editor" | "viewer";
    age?: number;
  }
*/
```

`parse()` throws a structured `ZodError` on failure. `safeParse()` returns a discriminated union and is usually the right choice in HTTP handlers because you control the error response:

```ts
app.post('/users', async (req, res) => {
  const result = CreateUserSchema.safeParse(req.body);

  if (!result.success) {
    // result.error.flatten() gives { fieldErrors: { email: ['Invalid email'] } }
    res.status(400).json({ errors: result.error.flatten().fieldErrors });
    return;
  }

  // result.data is typed as CreateUserInput — no cast, no guessing
  const user = await createUser(result.data);
  res.status(201).json(user);
});
```

> **Never duplicate.** The schema is the single source of truth. The TypeScript type is derived from it. Writing a separate `interface CreateUserInput` by hand and keeping it in sync with the Zod schema manually is a maintenance trap — they will diverge at the worst possible moment.

### Composing schemas

Zod schemas are composable. Build complex types from smaller pieces:

```ts
const PaginationSchema = z.object({
  page: z.coerce.number().int().positive().default(1),
  limit: z.coerce.number().int().min(1).max(100).default(20),
});

const UserQuerySchema = z
  .object({
    search: z.string().optional(),
    role: z.enum(['admin', 'editor', 'viewer']).optional(),
  })
  .merge(PaginationSchema);

type UserQuery = z.infer<typeof UserQuerySchema>;

// z.coerce.number() parses query-string values ("?page=2") correctly:
// req.query values are always strings — coerce converts before validating
const query = UserQuerySchema.parse(req.query);
// query.page is number 2, not string "2"
```

---

## Fastify: typed routes with native generics

Fastify has first-class TypeScript support. The request/response shapes are passed as generics and the framework types `req.body`, `req.params`, and `reply.send()` accordingly.

The canonical pattern pairs Fastify with Zod via `fastify-type-provider-zod`:

```ts
import Fastify from 'fastify';
import { serializerCompiler, validatorCompiler, ZodTypeProvider } from 'fastify-type-provider-zod';
import { z } from 'zod';

const app = Fastify();
app.setValidatorCompiler(validatorCompiler);
app.setSerializerCompiler(serializerCompiler);

const ParamsSchema = z.object({ id: z.string().uuid() });
const BodySchema = z.object({ name: z.string().min(1), price: z.number().positive() });
const ResponseSchema = BodySchema.extend({ id: z.string().uuid(), updatedAt: z.string() });

app.withTypeProvider<ZodTypeProvider>().route({
  method: 'PUT',
  url: '/products/:id',
  schema: {
    params: ParamsSchema,
    body: BodySchema,
    response: { 200: ResponseSchema },
  },
  handler: async (req, reply) => {
    // req.params.id is typed as string — validated before handler runs
    // req.body.name is typed as string — validated before handler runs
    const product = await updateProduct(req.params.id, req.body);
    return product; // TypeScript checks this matches ResponseSchema
  },
});
```

The validation runs before the handler. A bad body never reaches your logic — Fastify returns a 400 automatically.

---

## Express: grafting types onto an untyped design

Express predates TypeScript. Its `Request` type has `body: any`, and that `any` propagates everywhere. The mitigation is a validation middleware that runs before the handler:

```ts
import { z, ZodSchema } from 'zod';
import { Request, Response, NextFunction } from 'express';

// Augment the Express Request type to carry validated data
declare module 'express-serve-static-core' {
  interface Request {
    validated?: unknown;
  }
}

function validateBody<T>(schema: ZodSchema<T>) {
  return (req: Request, res: Response, next: NextFunction) => {
    const result = schema.safeParse(req.body);
    if (!result.success) {
      res.status(400).json({ errors: result.error.flatten().fieldErrors });
      return;
    }
    req.validated = result.data;
    next();
  };
}

app.post('/users', validateBody(CreateUserSchema), async (req, res) => {
  const input = req.validated as CreateUserInput; // one cast, at the boundary
  const user = await createUser(input);
  res.status(201).json(user);
});
```

> **The honest tradeoff.** Express requires you to wire this up yourself and live with the one remaining cast. Fastify's type provider eliminates even that. If you are starting a new service and TypeScript correctness matters, Fastify is the right choice. For an existing Express codebase, the middleware pattern above is the practical migration path.

---

## DTOs: separate the wire shape from the domain model

A **Data Transfer Object (DTO)** is what you expose over the API — not your database model. They are deliberately different shapes:

```ts
// Database row — contains internal / sensitive fields
interface UserRow {
  id: string;
  email: string;
  passwordHash: string;       // NEVER send this
  stripeCustomerId: string;   // internal ID
  createdAt: Date;
  deletedAt: Date | null;     // soft-delete signal, internal
}

// API response DTO — curated subset
const UserResponseSchema = z.object({
  id: z.string().uuid(),
  email: z.string().email(),
  createdAt: z.string().datetime(),
});
type UserResponse = z.infer<typeof UserResponseSchema>;

function toUserResponse(row: UserRow): UserResponse {
  // parse() here strips any extra fields not in the schema
  // even if UserRow grows new sensitive columns, they won't leak
  return UserResponseSchema.parse({
    id: row.id,
    email: row.email,
    createdAt: row.createdAt.toISOString(),
  });
}
```

Calling `UserResponseSchema.parse()` inside the mapper is a deliberate second parse. It is cheap and catches the case where someone adds a field to the spread without thinking about what gets serialised.

---

## Error types: discriminated unions for typed failure paths

Untyped errors — `throw new Error("not found")` — force every caller to parse string messages. A discriminated union makes the error machine-readable:

```ts
type AppError =
  | { type: 'NOT_FOUND'; resource: string; id: string }
  | { type: 'VALIDATION_FAILED'; errors: Record<string, string[]> }
  | { type: 'CONFLICT'; message: string }
  | { type: 'UNAUTHORIZED' }
  | { type: 'INTERNAL'; cause: unknown };

function errorToHttpResponse(err: AppError): { status: number; body: object } {
  switch (err.type) {
    case 'NOT_FOUND':
      return { status: 404, body: { error: `${err.resource} ${err.id} not found` } };
    case 'VALIDATION_FAILED':
      return { status: 400, body: { errors: err.errors } };
    case 'CONFLICT':
      return { status: 409, body: { error: err.message } };
    case 'UNAUTHORIZED':
      return { status: 401, body: { error: 'Unauthorized' } };
    case 'INTERNAL':
      return { status: 500, body: { error: 'Internal server error' } };
  }
}
```

TypeScript enforces exhaustive coverage of the switch. Add `| { type: 'RATE_LIMITED'; retryAfter: number }` and every `switch (err.type)` in the project that doesn't handle it becomes a compile error. This is the discipline that prevents "unhandled error type silently becomes 500."

---

## End-to-end types: the tRPC idea

[tRPC](https://trpc.io) takes schema-first to its logical conclusion. You define your API as typed TypeScript functions on the server. The client imports the router type and gets full autocomplete and type-checking — no code generation, no OpenAPI YAML, no sync step:

```
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│  Server defines                  Client uses                    │
│                                                                 │
│  const appRouter = router({      const user = await            │
│    user: router({                  trpc.user.getById.query(     │
│      getById: procedure            { id: '...' }               │
│        .input(z.object({         );                            │
│          id: z.string().uuid()   // id autocompletes           │
│        }))                       // return type is inferred    │
│        .query(({ input }) =>     // compile error if wrong     │
│          getUser(input.id)                                     │
│        ),                                                      │
│    }),                                                          │
│  });                                                            │
│                                                                 │
│  export type AppRouter = typeof appRouter; // the contract      │
└─────────────────────────────────────────────────────────────────┘
```

tRPC is ideal in a monorepo where the Next.js frontend and backend share a TypeScript codebase. For a public REST API consumed by external clients in other languages, REST + Zod + OpenAPI generation is the more practical choice.

---

## Debugging type safety

### Symptom → cause → fix

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| TypeScript compiles; runtime `TypeError: Cannot read property of undefined` | `as` cast on unvalidated input — type and actual data diverged | Replace every `as T` on external data with `Schema.safeParse()` |
| `any` spreads through the codebase; no type errors anywhere | `req.body` typed as `any`; no `strict` mode; untyped library return | Enable `"strict": true`; parse at the boundary; add `@types/` package |
| Validation passes in dev, wrong data reaches DB in production | Schema coercion gap — e.g. env sends `"true"` (string), schema expects `boolean` | Use `z.coerce.boolean()` or explicit `.transform()` at the boundary |
| `ZodError: Expected string, received number` after client update | Client changed payload shape without a contract | Generate OpenAPI spec from Zod schemas; version the endpoint |
| Schema and TypeScript type duplicated; they diverge over time | Hand-written interface alongside a Zod schema | Delete the interface; use `z.infer<typeof Schema>` everywhere |

### Finding `any` leaks

`any` is contagious — once a variable is `any`, every property access on it is also `any`, silently:

```ts
const raw: any = JSON.parse(data);
const email = raw.email;          // any
const lower = email.toLowerCase(); // any — TypeScript won't catch missing method
```

Find existing leaks in a codebase:

```bash
# explicit `any` annotations
grep -rn ': any' src/ --include='*.ts'

# explicit casts
grep -rn 'as any' src/ --include='*.ts'

# TypeScript can surface implicit any if you're not on strict mode yet:
# add "noImplicitAny": true to tsconfig.json and run tsc --noEmit
```

For gradual adoption in a large codebase, ESLint's `@typescript-eslint/no-explicit-any` with `"warn"` lets you see the scope before turning it into a hard failure.

### Diagnosing a type/runtime mismatch

The pattern to look for is data that arrives as one type and is treated as another without a parse step:

```ts
// Symptom: price calculations are wrong; 10 + 5 = "105"
const price = req.body.price; // string "100" from form encoding
const tax = price * 0.18;     // NaN — "100" * 0.18 is NaN

// Diagnosis: log the actual type at the boundary
console.log(typeof req.body.price); // "string" — not "number"

// Fix: coerce in the schema
const OrderSchema = z.object({
  price: z.coerce.number().positive(), // accepts "100" and converts to 100
});
```

> **War story.** At SAP, a metrics ingestion endpoint accepted `req.body as MetricPayload` and forwarded to Kafka directly. TypeScript was happy. One evening a client started sending `value: "NaN"` — a string — instead of `value: NaN`. The downstream consumer called `Math.max()` on the value six hops away and crashed. The write had succeeded (no validation), so the bad record sat in the topic and crashed every consumer that replayed it. We added a Zod schema at the HTTP boundary: `z.number()` rejects `"NaN"` with a 422. The bad data never reached Kafka. The fix was one schema change; the lesson was that an `as` cast in a write path is a time bomb with a Kafka-shaped fuse.

---

## Checkpoint

You are ready for the challenges in this course when you can, without looking anything up:

1. Explain why `req.body as CreateUserInput` compiles but is unsafe at runtime — and what you do instead.
2. Write a Zod schema for a `POST /orders` body (items array, total as number, optional discount), infer the TypeScript type from it, and validate an incoming request using `safeParse`.
3. Explain the difference between `parse` and `safeParse` and name one situation where each is the better choice.
4. Write a `toOrderResponse` function that takes a DB row with `internalCostCents` and `stripePaymentIntentId` fields and returns a DTO without them, using Zod to strip extras.
5. Define a four-variant `AppError` discriminated union and write an exhaustive switch that the TypeScript compiler enforces.
6. Explain in one sentence what tRPC gives you that REST + Zod does not — and name one situation where REST + Zod is still the better choice.
7. Locate all explicit `any` casts in a project using grep and explain which tsconfig option prevents new ones.

➡ Next up: **The Event Loop & Async Patterns** — why the single thread that handles all your requests must never be blocked, and how async/await can still go wrong in ways the syntax hides.
