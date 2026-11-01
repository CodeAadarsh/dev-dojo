# Solution — Route Handler: Typed API Endpoint

The complete `app/api/todos/route.ts`. Key points below the code.

```typescript
// app/api/todos/route.ts
export type Todo = { id: number; title: string; done: boolean }

const _store: Todo[] = []
let _nextId = 1

export function _reset(): void {
  _store.length = 0
  _nextId = 1
}

export async function GET(_req: Request): Promise<Response> {
  return new Response(JSON.stringify({ todos: _store }), {
    status: 200,
    headers: { 'content-type': 'application/json' },
  })
}

export async function POST(req: Request): Promise<Response> {
  let body: unknown
  try {
    body = await req.json()
  } catch {
    return new Response(JSON.stringify({ error: 'invalid JSON' }), {
      status: 422,
      headers: { 'content-type': 'application/json' },
    })
  }

  const { title } = body as Record<string, unknown>
  if (typeof title !== 'string' || title.trim() === '') {
    return new Response(JSON.stringify({ error: 'title must be a non-empty string' }), {
      status: 422,
      headers: { 'content-type': 'application/json' },
    })
  }

  const todo: Todo = { id: _nextId++, title: title.trim(), done: false }
  _store.push(todo)

  return new Response(JSON.stringify({ todo }), {
    status: 201,
    headers: { 'content-type': 'application/json' },
  })
}
```

## Why each piece matters

**No `next/server` import.**
Next.js route handlers receive a plain Web API `Request` and must return a plain Web API `Response`. You can import `NextResponse` for convenience helpers (cookies, redirects), but the contract is the Fetch API. Avoiding the import makes the module testable in any Node.js 18+ process — no framework bootstrapping, no build step.

**`status: 201` on the `new Response()`.**
The `Response` constructor accepts `{ status, headers }` as its second argument. Forgetting this defaults to 200. `201` carries a semantic promise: a resource was created. HTTP clients and CDN edge caches treat it differently from 200.

**`422 Unprocessable Entity` over `400 Bad Request`.**
`400` means "I couldn't parse your request." `422` means "I parsed it fine but the content fails my domain rules." A missing or blank `title` is a validation failure, not a syntax error — `422` is the precise signal. Some teams use `400` for both; the RFC says `422`.

**Trim before storing.**
`title.trim()` catches the case where the client sends `"   "` (blank after trim). The harness tests for this explicitly. Without it, a whitespace-only title passes the `typeof` check but stores a semantically-empty todo.

**`_reset()` is a test utility, not production code.**
In real Next.js, each request shares the module-level store because Node.js modules are cached for the lifetime of the process (or the Vercel function instance). `_reset()` is exported so the test harness can isolate cases — it would never appear in production source. Knowing this boundary matters: in a real app, an in-memory store is fine for a toy but dies on multi-replica deploys (use Redis or a DB).

## Apply and verify

```bash
cd ~/.kube-dojo-work/01-route-handler-api
# replace app/api/todos/route.ts with the solution above, then:
node --import tsx/esm --test 'test/sample.test.mts'
bash courses/course-32-nextjs-production/challenges/01-route-handler-api/verify.sh
```
