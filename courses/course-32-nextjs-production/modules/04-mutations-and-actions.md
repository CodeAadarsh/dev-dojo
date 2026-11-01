# Server Actions & Mutations

> **Module 04 · Course 32** — Server Actions are the first genuinely new primitive the App Router introduced: RPC-like functions that run on the server, callable from forms and Client Components without a hand-rolled API endpoint. They also introduce the only place in React where you mix server and client trust in a single function call, which makes their security model worth understanding deeply.

You've probably used Server Actions in a tutorial. This module is about using them at production scale: auth-gating correctly, designing the revalidation strategy, composing with optimistic UI, and knowing when to reach for a Route Handler instead.

---

## Server Actions

A Server Action is an async function marked `'use server'`. The compiler assigns it a URL-like identity and wraps every call in a POST request — invisible to the developer, but it means every Server Action is an HTTP endpoint with your server's authority.

Two places to define them:

```ts
// 1. In a dedicated 'use server' file (recommended for shared actions)
// app/actions/posts.ts
'use server'
import { db } from '@/lib/db'
import { posts } from '@/lib/db/schema'
import { revalidateTag } from 'next/cache'
import { getSession } from '@/lib/auth'

export async function createPost(data: FormData) {
  const session = await getSession()
  if (!session) throw new Error('Unauthorized')    // always auth-gate first

  const title = data.get('title') as string
  const body = data.get('body') as string

  await db.insert(posts).values({ title, body, authorId: session.userId })
  revalidateTag('posts')
}
```

```tsx
// 2. Inline in a Server Component (fine for simple, co-located actions)
// app/posts/[id]/page.tsx
export default async function PostPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params

  async function deletePost() {
    'use server'
    await db.delete(posts).where(eq(posts.id, id))
    revalidatePath('/posts')
    redirect('/posts')
  }

  return (
    <form action={deletePost}>
      <button type="submit">Delete post</button>
    </form>
  )
}
```

The inline syntax is convenient for simple co-located mutations. For anything shared across routes, or anything complex enough to test independently, use a separate `app/actions/` file.

---

## Forms & progressive enhancement

The `action` prop on a `<form>` can be a Server Action directly. This is progressive enhancement: the form works without JavaScript via a standard HTTP POST, and React enhances it with client-side transitions when JS is available.

```tsx
// app/posts/new/page.tsx — works without JavaScript
import { createPost } from '@/app/actions/posts'

export default function NewPostPage() {
  return (
    <form action={createPost}>
      <input name="title" type="text" required placeholder="Title" />
      <textarea name="body" required placeholder="Body" />
      <button type="submit">Publish</button>
    </form>
  )
}
```

With `useActionState` (React 19 / Next.js 15) for client-side error state and pending UI:

```tsx
'use client'
import { useActionState } from 'react'
import { createPost } from '@/app/actions/posts'

type State = { error: string | null; success: boolean }
const initial: State = { error: null, success: false }

export function NewPostForm() {
  const [state, formAction, isPending] = useActionState<State, FormData>(
    async (_prev, formData) => {
      try {
        await createPost(formData)
        return { error: null, success: true }
      } catch (e) {
        return { error: (e as Error).message, success: false }
      }
    },
    initial
  )

  if (state.success) return <p>Post published!</p>

  return (
    <form action={formAction}>
      {state.error && <p role="alert" className="text-red-500">{state.error}</p>}
      <input name="title" type="text" required />
      <textarea name="body" required />
      <button type="submit" disabled={isPending}>
        {isPending ? 'Publishing…' : 'Publish'}
      </button>
    </form>
  )
}
```

`useActionState` gives you the server's return value, a pending flag, and a form action reference. The form still degrades to a standard POST without JavaScript — `isPending` and `state` just won't update.

---

## revalidatePath and revalidateTag

After a mutation, invalidate cached data. The two primitives and when to use each:

```ts
import { revalidatePath, revalidateTag } from 'next/cache'

// Invalidate a specific URL — triggers full route cache revalidation for that path
revalidatePath('/posts')            // exact path
revalidatePath('/posts', 'page')    // only the page segment (not layouts above it)
revalidatePath('/posts', 'layout')  // the layout and all pages beneath it

// Invalidate by tag — all fetches and unstable_cache calls tagged with this name
revalidateTag('posts')              // any fetch({ next: { tags: ['posts'] } }) or unstable_cache with tags: ['posts']
```

Use `revalidateTag` when the mutated data appears on multiple routes (a user update that shows in the header, profile page, and activity feed). Use `revalidatePath` when the mutation only affects one specific route.

Both can only be called from Server Actions and Route Handlers — not directly from Client Components.

---

## Optimistic UI

`useOptimistic` (React 19+) updates the UI instantly while the server mutation is pending, then reconciles with the server response:

```tsx
'use client'
import { useOptimistic, useTransition } from 'react'
import { toggleLike } from '@/app/actions/likes'

type Post = { id: string; liked: boolean; likeCount: number }

export function LikeButton({ post }: { post: Post }) {
  const [optimisticPost, setOptimisticPost] = useOptimistic(
    post,
    (current, newLiked: boolean) => ({
      ...current,
      liked: newLiked,
      likeCount: current.likeCount + (newLiked ? 1 : -1),
    })
  )
  const [isPending, startTransition] = useTransition()

  function handleClick() {
    startTransition(async () => {
      setOptimisticPost(!optimisticPost.liked)       // instant UI update
      await toggleLike({ postId: post.id })          // server action
      // if the action throws, optimistic state reverts automatically
    })
  }

  return (
    <button onClick={handleClick} aria-disabled={isPending}>
      {optimisticPost.liked ? '♥' : '♡'} {optimisticPost.likeCount}
    </button>
  )
}
```

`useOptimistic` is available in React 19+ (Next.js 15). For Next.js 14, the pattern is `useState` + `useTransition` with manual rollback in the `catch` block:

```tsx
// Next.js 14 fallback pattern
const [liked, setLiked] = useState(post.liked)
const [count, setCount] = useState(post.likeCount)
const [isPending, startTransition] = useTransition()

function handleClick() {
  const wasLiked = liked
  const wasCount = count
  setLiked(!liked)
  setCount(c => c + (!liked ? 1 : -1))

  startTransition(async () => {
    try {
      await toggleLike({ postId: post.id })
    } catch {
      setLiked(wasLiked)   // roll back on error
      setCount(wasCount)
    }
  })
}
```

---

## Route Handlers

Route Handlers (`app/api/*/route.ts`) are the App Router's replacement for `pages/api/*`. They handle HTTP methods explicitly and are the right tool when you need a standard HTTP API surface:

```ts
// app/api/posts/route.ts
import { NextRequest, NextResponse } from 'next/server'
import { getSession } from '@/lib/auth'
import { db } from '@/lib/db'
import { posts } from '@/lib/db/schema'
import { desc } from 'drizzle-orm'
import { revalidateTag } from 'next/cache'

export async function GET(req: NextRequest) {
  const limit = Number(req.nextUrl.searchParams.get('limit') ?? '20')
  const rows = await db.select().from(posts).orderBy(desc(posts.createdAt)).limit(limit)
  return NextResponse.json(rows)
}

export async function POST(req: NextRequest) {
  const session = await getSession()
  if (!session) return NextResponse.json({ error: 'Unauthorized' }, { status: 401 })

  const body = await req.json()
  const [post] = await db.insert(posts).values({ ...body, authorId: session.userId }).returning()
  revalidateTag('posts')
  return NextResponse.json(post, { status: 201 })
}
```

Dynamic Route Handler with params:

```ts
// app/api/posts/[id]/route.ts
import { eq } from 'drizzle-orm'

type Context = { params: Promise<{ id: string }> }

export async function DELETE(req: NextRequest, { params }: Context) {
  const { id } = await params
  const session = await getSession()
  if (!session) return NextResponse.json({ error: 'Unauthorized' }, { status: 401 })

  const [deleted] = await db.delete(posts).where(eq(posts.id, id)).returning()
  if (!deleted) return NextResponse.json({ error: 'Not found' }, { status: 404 })

  revalidateTag('posts')
  return new Response(null, { status: 204 })
}
```

---

## Server Actions vs Route Handlers: when to use which

| Criterion | Server Action | Route Handler |
|-----------|--------------|---------------|
| Caller | React component (form, button) | External clients, mobile apps, curl |
| Transport | Framework-managed POST | Standard HTTP |
| Auth | Session cookies forwarded automatically | Must verify auth header or cookie manually |
| Progressive enhancement | Yes — form works without JS | No |
| Streaming responses | No | Yes (`Response` + `ReadableStream`) |
| Webhooks (inbound) | No | Yes |
| Caching control | `revalidate*` functions | Same |
| Type-safe end-to-end | Yes (shared action types) | Needs manual schema (zod, etc.) |

The rule of thumb: use Server Actions for UI mutations initiated by the logged-in user. Use Route Handlers when the caller is not a browser component (mobile app, external service, webhook, curl).

---

## Debugging Server Actions & Mutations

Server Actions fail silently more often than they fail loudly. The most common bugs are revalidation that doesn't run, auth checks that are missing or in the wrong place, and serialization errors that only appear in production builds.

### Symptom → cause → fix

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Action completes but page shows stale data | `revalidatePath`/`revalidateTag` not called, wrong path, or full route cache not invalidated | Confirm the revalidate call is inside the action and the string matches exactly |
| `TypeError: myAction is not a function` on the client | File not marked `'use server'` or import resolves to wrong file | Confirm the file starts with `'use server'` at the top (before any imports) |
| `Error: Only plain objects, and a few built-ins, can be passed to Server Actions` | Passing a non-serializable argument (class instance, `Date`, Symbol, function) | Serialize to primitives before calling the action (dates → ISO string) |
| Form does not reset after success | Form state not cleared after a successful submission | Use `key` prop on the form to force remount on success, or call `formRef.current?.reset()` |
| Action succeeds in dev but fails silently in production | Serialization constraint is stricter in production builds | Test actions by calling them in a preview deploy, not just `next dev` |
| CSRF: action callable from any origin | No auth check — any POST can invoke the action | Auth-gate as the first line of every action; never trust client-supplied user IDs |

### Diagnosing action not revalidating

**Step 1: Confirm the revalidate call actually runs.**

```ts
'use server'
export async function updatePost(data: FormData) {
  await db.update(posts).set(...)  // if this throws, revalidate never runs
  console.log('[updatePost] revalidating posts tag')
  revalidateTag('posts')
  console.log('[updatePost] done')
}
```

If only the first log appears, the DB call is throwing. Check server logs for the full error.

**Step 2: Confirm the tag or path string matches.**

```ts
// Action uses:
revalidateTag('posts')

// But your query uses:
export const getPostList = unstable_cache(
  async () => db.select().from(posts),
  ['post-list'],             // ← different key
  { tags: ['post'] }         // ← 'post' not 'posts' — tag mismatch
)
```

The tag in `revalidateTag` must match the tag in the `fetch` option or `unstable_cache` config exactly.

**Step 3: Is the route static and self-hosted?**

On Vercel, `revalidateTag` clears both the data cache and the full route cache globally. On self-hosted Next.js with multiple instances, each process has its own in-memory full route cache. `revalidateTag` only clears the instance that handled the action. Use `revalidatePath` in addition, and consider a shared cache handler (Redis-backed `@neshca/cache-handler`) for multi-instance deployments.

### Diagnosing CSRF and auth on actions

Every Server Action is an HTTP endpoint callable from any origin. Next.js adds a `Same-Origin` origin check for actions invoked via the `<form>` `action` attribute, but actions called programmatically (`startTransition(async () => await myAction(...))`) bypass it.

**The rule: auth-gate every action, treat every argument as untrusted.**

```ts
// Bad — relies on the caller to pass the correct userId
export async function deletePost(postId: string, userId: string) {
  await db.delete(posts).where(and(eq(posts.id, postId), eq(posts.authorId, userId)))
}
// Any authenticated session can call deletePost('any-post-id', 'any-user-id')

// Good — action reads the session itself
export async function deletePost(postId: string) {
  const session = await getSession()
  if (!session) throw new Error('Unauthorized')

  const [post] = await db.select().from(posts).where(eq(posts.id, postId))
  if (!post || post.authorId !== session.userId) throw new Error('Forbidden')

  await db.delete(posts).where(eq(posts.id, postId))
  revalidatePath('/posts')
}
```

Never pass `userId` as an argument from the client. Read it from the server-side session cookie. The session is the trust anchor — everything else is user-supplied input.

### Diagnosing serialization errors

`Error: Only plain objects, and a few built-ins, can be passed to Server Actions. Classes or null prototypes are not supported.`

This fires in production but may silently work in dev (which has looser serialization for DX). Common causes:

```tsx
'use client'
// Bad — Date object is not a plain JSON value
await createEvent({ title: 'Launch', date: new Date() })

// Good — serialize to ISO string; parse back in the action
await createEvent({ title: 'Launch', date: new Date().toISOString() })
```

```ts
// In the action, parse back:
'use server'
export async function createEvent(data: { title: string; date: string }) {
  const date = new Date(data.date)   // parse ISO string
  await db.insert(events).values({ title: data.title, date })
}
```

For complex forms with many field types, use a `zod` schema at the action boundary to coerce and validate:

```ts
import { z } from 'zod'

const CreateEventSchema = z.object({
  title: z.string().min(1),
  date: z.string().datetime().transform(s => new Date(s)),
})

export async function createEvent(data: FormData) {
  const session = await getSession()
  if (!session) throw new Error('Unauthorized')

  const parsed = CreateEventSchema.safeParse({
    title: data.get('title'),
    date: data.get('date'),
  })
  if (!parsed.success) throw new Error(parsed.error.issues[0].message)

  await db.insert(events).values({ ...parsed.data, creatorId: session.userId })
  revalidateTag('events')
}
```

The `zod` schema at the action boundary catches serialization and validation problems as a user-facing error rather than an internal crash, and documents the expected types at the action signature.

> **War story.** We had a multi-step form wizard — each step a Client Component accumulating state, with a final "submit all" button that called a Server Action with the full accumulated state. On step 3 we added a date picker that set a `Date` object into the form state. The Server Action started throwing with a vague "class not supported" error in production, but worked perfectly in dev. The test suite ran in dev mode — never caught it. The lesson: always run a quick smoke test of your Server Actions against a preview deployment after adding any complex types. The serialization constraint is enforced strictly only in production. We added a `zod` schema to every action that accepts a date, coercing to ISO string, and the problem hasn't recurred since.

---

## Checkpoint

You're ready for the challenges when you can, without looking anything up:

1. Write a `'use server'` file with a `createPost` action that auth-gates via session, inserts a row, and calls `revalidateTag`.
2. Attach the action to a `<form>` element so the form submits correctly without JavaScript (progressive enhancement).
3. Implement `useActionState` to display a server-returned error message below the form after a failed submit.
4. Use `useOptimistic` to update a like count instantly while the Server Action is in-flight, and roll back if it throws.
5. Implement a `DELETE /api/posts/[id]` Route Handler that returns 204 on success, 404 if the post doesn't exist, and 401 if not authenticated.
6. Explain why you must never trust a `userId` passed as an argument to a Server Action, and write the secure version that reads from the session.
7. Diagnose "action completes but page shows old data" using the three-step revalidation checklist (logs, tag match, full route cache).
8. Explain when to use `revalidatePath` vs `revalidateTag` and give a concrete scenario for each.
9. State the one production-only behavior that makes Server Action serialization bugs impossible to catch in `next dev`.

➡ Next up: **Route Handlers & Middleware** — streaming responses, edge runtime, request transformation, and auth at the CDN edge.
