# Solution — Server Action: Validated Form Submission

The complete `actions/contact.ts`. Key points below the code.

```typescript
'use server'

export type Contact = {
  id: string
  name: string
  email: string
  createdAt: string
}

export type ActionResult<T> =
  | { ok: true; data: T }
  | { ok: false; error: string }

export async function submitContact(input: {
  name: string
  email: string
}): Promise<ActionResult<Contact>> {
  const name = input.name.trim()
  if (name === '') {
    return { ok: false, error: 'name must not be empty' }
  }

  const email = input.email.trim()
  if (email === '' || !email.includes('@')) {
    return { ok: false, error: 'email must contain @' }
  }

  const contact: Contact = {
    id: crypto.randomUUID(),
    name,
    email,
    createdAt: new Date().toISOString(),
  }

  return { ok: true, data: contact }
}
```

## Why each piece matters

**`'use server'` at the top.**
This directive is how the Next.js compiler identifies a Server Actions module. It cannot be in a `'use client'` file. For local testing, the directive is ignored by the Node.js runtime — it's just a string literal — so the import works cleanly in `node --test`.

**Return `{ ok: false }` instead of throwing.**
A thrown error inside a Server Action propagates as a serialised `Error` with `digest` only. The client component receives no structured data about *what* went wrong. The `ActionResult<T>` discriminated union lets the component do an exhaustive `if (result.ok)` check at the TypeScript level — the compiler won't let you access `result.data` without first checking `result.ok === true`.

**`crypto.randomUUID()` without an import.**
Node 18+ ships `crypto` as a global with `randomUUID()`. No `import { randomUUID } from 'node:crypto'` needed, matching how Next.js server code would use it (the global is also available in Vercel Edge Runtime, Workers, etc.).

**Trim before validation.**
`input.name.trim()` catches `"   "` (blank after trim). The harness tests this case explicitly. Checking `name.length === 0` *before* trimming would pass `"   "` as valid — the trim-then-check order is the right one.

**`ActionResult<T>` as a generic.**
The `T` makes the type reusable across all Server Actions in the app. `submitContact` returns `ActionResult<Contact>`; a `createOrder` action would return `ActionResult<Order>`. The calling component always gets the same outer shape regardless of what `data` contains, so a single error-rendering path handles everything.

## Apply and verify

```bash
cd ~/.kube-dojo-work/02-server-action
# replace actions/contact.ts with the solution above, then:
node --import tsx/esm --test 'test/sample.test.mts'
bash courses/course-32-nextjs-production/challenges/02-server-action/verify.sh
```
