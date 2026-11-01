# Data Fetching & Caching

> **Module 03 · Course 32** — Next.js 15 ships four distinct caching layers that interact in non-obvious ways. Getting caching right is the difference between a sub-50 ms TTFB and a 2-second page load on every request. Getting it wrong means stale data in production that "can't be reproduced locally."

The four layers: request memoization (per-render-pass), data cache (per-deployment), full route cache (pre-rendered HTML), and client router cache (browser-side navigation). This module covers the first two in depth and shows how the latter two follow from them.

---

## The fetch cache

`fetch` in Server Components is extended by Next.js to support a request-level data cache. The default **changed between versions**:

- **Next.js 14**: `fetch` defaults to `force-cache` — cached indefinitely unless you opt out.
- **Next.js 15**: `fetch` defaults to uncached (`no-store`) — opt in to caching explicitly.

```ts
// Uncached — fresh data on every request (default in Next.js 15)
const data = await fetch('https://api.example.com/posts')

// Cache indefinitely until manually invalidated
const data = await fetch('https://api.example.com/posts', {
  cache: 'force-cache',
})

// Time-based revalidation — re-fetch after 60 seconds at most
const data = await fetch('https://api.example.com/posts', {
  next: { revalidate: 60 },
})

// Tag-based revalidation — re-fetch when 'posts' tag is invalidated
const data = await fetch('https://api.example.com/posts', {
  next: { tags: ['posts'] },
})
```

The data cache is **per-deployment**, not per-server-instance. On Vercel, `revalidateTag('posts')` invalidates all routes tagged `posts` across every edge replica simultaneously. Self-hosted, each process has its own cache unless you plug in a shared cache adapter.

This only applies to `fetch`. For ORM queries (Drizzle, Prisma), use `unstable_cache` or the `use cache` directive.

---

## `unstable_cache` and `use cache`

Most real apps query a database, not a REST API. `unstable_cache` wraps any async function with the same semantics as `fetch`'s `next` option:

```ts
import { unstable_cache } from 'next/cache'
import { db } from '@/lib/db'
import { posts } from '@/lib/db/schema'
import { desc } from 'drizzle-orm'

export const getPosts = unstable_cache(
  async () => {
    return db.select().from(posts).orderBy(desc(posts.createdAt)).limit(20)
  },
  ['posts-list'],           // cache key — array of strings
  {
    revalidate: 60,         // seconds until stale-while-revalidate kicks in
    tags: ['posts'],        // tag for on-demand invalidation
  }
)
```

Next.js 15 adds the `use cache` directive — a cleaner, compiler-native version:

```ts
// app/lib/queries.ts
import { cacheTag, cacheLife } from 'next/dist/server/use-cache/cache-tags'
import { db } from '@/lib/db'

export async function getPosts() {
  'use cache'
  cacheTag('posts')
  cacheLife('minutes')   // built-in profile: revalidate: 60, stale-while-revalidate: 300

  return db.select().from(posts).orderBy(desc(posts.createdAt)).limit(20)
}
```

`use cache` makes caching intent explicit at the function level. The compiler transforms it into the same underlying mechanism as `unstable_cache`. Use `use cache` in new Next.js 15 code; use `unstable_cache` when supporting Next.js 14.

> **Mental model.** Think of the data cache like HTTP's `Cache-Control` but for server-side function results. `force-cache` = `public, immutable`. `revalidate: 60` = `s-maxage=60, stale-while-revalidate`. `no-store` = `no-cache, no-store`. The same trade-offs apply: freshness vs latency vs server load.

---

## Dynamic vs static rendering

Next.js renders each route at build time (static) or at request time (dynamic) based on signals it detects:

```
Static rendering (build time):
  ✓ No dynamic functions called (cookies, headers, searchParams)
  ✓ No uncached data fetches
  ✓ generateStaticParams covers all params (or dynamicParams = false)
  → HTML generated once, served from CDN cache, zero DB load at runtime

Dynamic rendering (per request):
  ✗ cookies() or headers() called anywhere in the route tree
  ✗ Any uncached fetch (no-store, or default in Next.js 15)
  ✗ searchParams accessed in the page component
  → HTML generated fresh per request; every request hits your server
```

Dynamic functions make the **entire route** dynamic, not just the component that calls them. A single `cookies()` call buried four components deep flips the whole route:

```tsx
// This makes the ENTIRE route dynamic, not just this component:
export function UserGreeting() {
  const cookieStore = cookies()    // 'next/headers' — dynamic function
  const name = cookieStore.get('username')?.value ?? 'there'
  return <span>Hello, {name}</span>
}
```

If you need auth state but want to keep most of the route static, use Partial Prerendering.

---

## Partial Prerendering (PPR)

PPR lets a single route have a static shell and dynamic holes delivered in one HTTP response:

```
Request → CDN (cache hit — static shell served immediately)
                ↕ streaming (same TCP connection)
Edge function → dynamic fragments stream in as Promises resolve
```

Enable incrementally per-route:

```ts
// next.config.ts
export default {
  experimental: { ppr: 'incremental' },
}
```

```tsx
// app/dashboard/page.tsx
export const experimental_ppr = true

import { Suspense } from 'react'
import { StaticHero } from '@/components/static-hero'   // pre-rendered at build
import { UserFeed } from '@/components/user-feed'         // dynamic, streamed

export default function DashboardPage() {
  return (
    <>
      <StaticHero />                               {/* in static shell */}
      <Suspense fallback={<FeedSkeleton />}>
        <UserFeed />                               {/* dynamic hole */}
      </Suspense>
    </>
  )
}
```

`<StaticHero />` is served from the CDN cache — zero server load for that subtree. `<UserFeed />` streams in on the same connection after the static shell arrives. `<FeedSkeleton />` is part of the static shell, so the user sees layout immediately while data loads.

The rule: **every `<Suspense>` boundary wrapping a dynamic component becomes a PPR hole.** Everything outside Suspense boundaries is pre-rendered. PPR requires the `experimental_ppr` flag on Next.js 14.1+ or is stable in Next.js 15.

---

## Request memoization

Within a single server render, identical `fetch` calls to the same URL are deduplicated automatically. This is separate from the cross-request data cache — it lives only for the duration of one render tree.

```ts
// Both called during the same request — only one HTTP call goes out
const user = await fetch('/api/user/1')   // in layout.tsx
const user = await fetch('/api/user/1')   // in page.tsx — deduplicated automatically
```

For ORM calls, use React's `cache()`:

```ts
import { cache } from 'react'
import { db } from '@/lib/db'
import { users } from '@/lib/db/schema'
import { eq } from 'drizzle-orm'

export const getUser = cache(async (id: string) => {
  const [user] = await db.select().from(users).where(eq(users.id, id)).limit(1)
  return user ?? null
})

// Called in layout.tsx and page.tsx for the same request — DB queried once
```

`cache()` is a React API (not Next.js-specific) that memoizes results for the current render tree. The memo resets per request — it does not persist to the data cache. Use it to prevent redundant DB calls when the same data is needed in multiple components on the same page.

---

## Combining the caching layers

A production data flow uses all three:

```ts
// lib/queries/posts.ts
import 'server-only'
import { cache } from 'react'
import { unstable_cache } from 'next/cache'
import { db } from '@/lib/db'

// 1. Request memoization: deduplicate within one render pass
// 2. Data cache: persist result across requests for 60s
export const getPosts = cache(
  unstable_cache(
    async () => db.select().from(posts).orderBy(desc(posts.createdAt)).limit(20),
    ['posts-list'],
    { revalidate: 60, tags: ['posts'] }
  )
)
```

- `cache()` deduplicates within the current render (layout + page both call `getPosts` → one DB call).
- `unstable_cache` persists the result across requests for up to 60 seconds.
- `revalidateTag('posts')` from a Server Action blows through both layers and forces a fresh DB call on the next request.

---

## Debugging Data Fetching & Caching

Caching bugs are the hardest class in Next.js because they're invisible: the code is correct, the data is wrong, and only production has the problem. The key insight is that diagnosing stale data means identifying *which layer* is holding old data.

### Symptom → cause → fix

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Page shows stale data in production but is correct in dev | Data cache holding old fetch/query result | Add `revalidatePath`/`revalidateTag` in the mutation path, or set a shorter `revalidate` interval |
| `next dev` shows dynamic but `next build` shows static (or vice versa) | Dev disables the full route cache for DX; trust the build output | Add `export const dynamic = 'force-dynamic'` if you need per-request rendering in prod |
| `revalidateTag` called but page still shows old data | Tag mismatch, or route also in the full route cache on self-hosted | Confirm tag strings match exactly; on self-hosted also call `revalidatePath` |
| Route shows `λ` in build output when it should be `○` | A dynamic function (`cookies`, `headers`, `searchParams`) called in the route tree | Find and remove the call, or wrap the dynamic part in `<Suspense>` with PPR |
| `unstable_cache` data never expires | Missing `revalidate` or `tags` option | Add `{ revalidate: N }` or `{ tags: ['...'] }` as the third argument |

### Diagnosing stale data in production

**Step 1: Check the rendering mode.**

```bash
npm run build
# Route symbols:
# ○ = static (pre-rendered, served from full route cache)
# λ = dynamic (server-rendered per request)
# ◐ = PPR (static shell + dynamic holes)
```

A route showing `○` when you expect fresh data will only update on revalidation or redeploy. That's the full route cache — a separate layer on top of the data cache.

**Step 2: Check what your infrastructure returns.**

```bash
curl -sI https://yoursite.com/posts | grep -i 'cache\|age\|x-vercel'
# On Vercel:
# x-vercel-cache: HIT   → served from Vercel's edge cache
# x-vercel-cache: MISS  → fetched from your origin
# x-vercel-cache: STALE → served stale while revalidating in background
# age: 3600             → cached for 1 hour
```

If `x-vercel-cache: HIT` and `age: 86400`, Next.js's cache is being bypassed by a CDN layer. Check `Cache-Control` response headers — a custom Nginx or CDN in front of Next.js can override your caching strategy entirely.

**Step 3: Add debug logging to the cache function.**

```ts
export const getPosts = unstable_cache(
  async () => {
    console.log('[getPosts] cache miss — querying DB at', new Date().toISOString())
    return db.select().from(posts)
  },
  ['posts-list'],
  { revalidate: 60, tags: ['posts'] }
)
```

In `next dev` you should see the log on every request (dev never caches). In production (`next start`), you should see it at most once per 60 seconds. If you never see it in production, the data cache is holding the result correctly — look at the full route cache or CDN layer instead.

### Diagnosing accidental dynamic rendering

Bisect to find which component is making the route dynamic:

```bash
npm run build 2>&1 | grep "○\|λ\|◐" | grep "dashboard"
# If /dashboard shows λ, something in that route calls a dynamic function
```

Comment out each `cookies()`/`headers()` call in the route tree until the route flips from `λ` to `○` in the build output. The last one you commented out is the trigger.

For a faster trace, temporarily add `export const dynamic = 'force-static'` to the page. Next.js will throw a build error naming the dynamic function call:

```ts
// app/dashboard/page.tsx
export const dynamic = 'force-static'   // add temporarily
// Build error: "Dynamic server usage: cookies() is not supported 'force-static'"
```

Remove it after identifying the problem.

### Diagnosing cache not revalidating

Four-point checklist for "I called `revalidateTag` but the data is still old":

**1. Is the tag spelled correctly?** `revalidateTag('post')` does not invalidate `{ tags: ['posts'] }`. They must match exactly.

**2. Is the fetch/query actually tagged?**

```ts
// Confirm by logging inside the unstable_cache wrapper
export const getPosts = unstable_cache(
  async () => { console.log('fetching posts'); return db... },
  ['posts-list'],
  { tags: ['posts'] }    // ← is this here?
)
```

**3. Is the route in the full route cache?**

`revalidateTag` invalidates the data cache. On Vercel, it also invalidates the full route cache. On self-hosted Next.js, the full route cache is per-instance and memory-resident — `revalidateTag` alone is not enough. Also call `revalidatePath`:

```ts
'use server'
export async function createPost(data: FormData) {
  await db.insert(posts).values(parsePost(data))
  revalidateTag('posts')          // data cache
  revalidatePath('/posts')        // full route cache (needed on self-hosted)
}
```

**4. Are you testing in dev?** `next dev` never uses the full route cache. A bug that "disappears in dev" and reappears in production is almost always a full route cache issue.

> **War story.** A product catalog at a previous job showed prices 24 hours stale. `revalidateTag('products')` was being called correctly on every admin mutation — we had logs proving it. The storefront route showed `λ` in the build, so the full route cache wasn't the issue. The actual culprit was an Nginx reverse proxy that sat in front of the Next.js server and was caching the HTML response for 24 hours via its own `proxy_cache_valid` directive. `curl -I` on the storefront URL showed `X-Cache: HIT` from Nginx, not Next.js — the request never reached Next.js at all. The fix was adding a `Cache-Control` response header export to the route that Nginx was configured to respect. The lesson: Next.js's cache and your infrastructure's cache are different systems. Always verify with `curl -sI` before assuming the Next.js layer is misbehaving.

---

## Checkpoint

You're ready for the challenges when you can, without looking anything up:

1. State the default caching behavior of `fetch` in Next.js 14 vs 15, and write the option for time-based revalidation with a 5-minute TTL.
2. Wrap a Drizzle ORM query with `unstable_cache` using a tag and 60-second revalidation.
3. Explain what "static rendering" vs "dynamic rendering" means for a route, and name two dynamic signals that flip it.
4. Implement a PPR route with a static hero section and a dynamic feed section in the same `page.tsx`.
5. Use React's `cache()` to deduplicate a DB call that is made from both `layout.tsx` and `page.tsx` in the same request.
6. Use the `force-static` override to identify which dynamic function call is preventing a route from being pre-rendered.
7. Trace a broken `revalidateTag` call through the four-point checklist (spelling, tagged, full route cache, dev vs prod).
8. Read the `X-Vercel-Cache` response header and explain what `HIT`, `MISS`, and `STALE` mean in the context of Vercel's edge.

➡ Next up: **Server Actions & Mutations** — forms, progressive enhancement, optimistic UI, and the route-handler vs action decision.
