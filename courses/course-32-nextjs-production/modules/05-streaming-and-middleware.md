# Streaming, Suspense & Middleware

> **Module 05 · Course 32** — A slow database query on one part of your page shouldn't hold the HTML hostage. Suspense makes the browser start painting before your slowest `await` finishes. Middleware lets you run logic at the CDN edge before a single component renders. Together they're the biggest reason the App Router is a genuine architectural shift, not just a rename.

You've seen `<Suspense>` in client React. In Next.js the same primitive reaches the HTTP wire — the server streams HTML chunks as they resolve, and the browser progressively hydrates. This module goes deep on when that matters, where to draw the boundaries, and how middleware fits into the request lifecycle before any component code runs.

---

## The waterfall problem and why streaming exists

The classic SSR model: server fetches everything, assembles a complete HTML document, flushes it. If you have three data dependencies and the slowest one takes 800 ms, your TTFB is 800 ms — even if the other two resolved in 20 ms.

```
Classic SSR (blocking)
──────────────────────────────────────────────────────────────────────────
request  ──►  layout fetch (20ms)  ─────────────────────────────────────┐
              sidebar fetch (50ms) ─────────────────────────────────────┤
              article fetch (800ms) ────────────────────────── flush HTML
              client starts painting at 800ms + network RTT
```

```
Streaming SSR (Suspense)
──────────────────────────────────────────────────────────────────────────
request  ──►  shell (layout + fallbacks) ──► flush immediately (20ms)
              sidebar resolves ───────────────► stream chunk (70ms)
              article resolves ──────────────────────────────────────► stream chunk (820ms)
              browser paints shell at 20ms, progressively fills in
```

The shell — everything outside your `<Suspense>` boundaries — flushes immediately. Each boundary is a deferred chunk that streams as its `await` resolves. The browser renders incrementally without client-side JS for the layout.

The constraint: anything outside a Suspense boundary that throws an unresolved promise blocks the shell. This is the most common mistake — a single awaited fetch at the root of a layout stalls everything.

---

## Suspense boundaries — placement is everything

### What the compiler actually does

When the server encounters a Suspense boundary it:

1. Begins rendering the subtree.
2. If any component in that subtree suspends (its async data isn't ready), substitutes the `fallback`.
3. Streams the rest of the document.
4. When the data resolves, streams an inline `<script>` that replaces the placeholder via the React streaming protocol.

This is transport-level streaming, not a client-side state update. The browser receives incremental chunks of HTML.

### Where to draw boundaries

Place a `<Suspense>` boundary around every independently slow data dependency. The goal is to make the shell as cheap as possible.

```tsx
// app/dashboard/page.tsx
import { Suspense } from 'react'
import { MetricsSkeleton, FeedSkeleton } from '@/components/skeletons'

// No top-level awaits here. The shell is cheap.
export default function DashboardPage() {
  return (
    <div className="grid grid-cols-2 gap-4">
      <Suspense fallback={<MetricsSkeleton />}>
        <MetricsPanel />      {/* hits a slow aggregation query */}
      </Suspense>
      <Suspense fallback={<FeedSkeleton />}>
        <ActivityFeed />      {/* hits a paginated log query */}
      </Suspense>
    </div>
  )
}
```

Each panel races independently. If `MetricsPanel` resolves in 200 ms and `ActivityFeed` takes 900 ms, the metrics are in the browser at 200 ms. There is no artificial coupling between them.

**Anti-pattern: one outer Suspense wrapping everything.** Not wrong, but it means the entire body is a fallback until the slowest dependency resolves — you've reinvented blocking SSR with extra steps.

**Anti-pattern: `await` in the layout.** A `layout.tsx` that does `const data = await fetch(...)` before returning JSX blocks every page that shares that layout. If you need data in the layout, push it into a Server Component child that lives inside a `<Suspense>`.

### Nested boundaries

You can nest Suspense. Inner boundaries resolve and stream before outer ones. React streams in document order — the outer placeholder is replaced only when its own direct suspension resolves, not when inner ones do.

---

## `loading.tsx` — Suspense via the file system

`loading.tsx` is syntactic sugar. Placing one in a route segment is exactly equivalent to wrapping `{children}` in that segment's layout with `<Suspense fallback={<Loading />}>`. Next.js does the wrapping for you.

```
app/
  dashboard/
    loading.tsx      ← rendered while page.tsx (and nested pages) are suspending
    page.tsx
    metrics/
      loading.tsx    ← more specific: only while metrics/page.tsx suspends
      page.tsx
```

The most specific `loading.tsx` wins. If you need different fallbacks for different components within a single page, use explicit `<Suspense>` inside `page.tsx` — `loading.tsx` only applies to the whole segment.

> **One non-obvious rule:** `loading.tsx` wraps the *page* in a Suspense, not the entire layout. The layout itself is rendered synchronously before the boundary — which is why a heavy `layout.tsx` still blocks. The boundary only guards the page content below it.

---

## Middleware — before any component renders

`middleware.ts` (at the project root or `src/`) runs **on the edge** before a request reaches any route handler or Server Component. Think of it as a lightweight programmable CDN rule that has access to the incoming `Request`.

```
┌──────────────────────────────────────────────────────────────────────┐
│  request arrives at CDN/edge node                                    │
│                                                                      │
│  middleware.ts  ─── match? ──yes──► (redirect | rewrite | response) │
│                        │                                             │
│                        no                                            │
│                        ▼                                             │
│              Next.js route resolution                                │
│              (RSC render / route handler / static file)             │
└──────────────────────────────────────────────────────────────────────┘
```

### Anatomy of a middleware file

```ts
// middleware.ts
import { NextRequest, NextResponse } from 'next/server'

export function middleware(request: NextRequest): NextResponse | void {
  // read cookies, headers, URL
  // return a NextResponse or let the request continue
}

export const config = {
  matcher: ['/dashboard/:path*', '/api/protected/:path*'],
}
```

If `middleware` returns nothing (or calls `NextResponse.next()`), the request continues to the route. If it returns a `NextResponse`, that response is sent — the route never executes.

### Common patterns

**Redirect unauthenticated users:**

```ts
export function middleware(request: NextRequest) {
  const token = request.cookies.get('session')?.value
  if (!token && request.nextUrl.pathname.startsWith('/dashboard')) {
    return NextResponse.redirect(new URL('/login', request.url))
  }
}
```

**Rewrite for A/B routing (without a URL change):**

```ts
export function middleware(request: NextRequest) {
  const bucket = request.cookies.get('ab_bucket')?.value ?? 'control'
  if (request.nextUrl.pathname === '/pricing') {
    return NextResponse.rewrite(
      new URL(`/pricing-${bucket}`, request.url)
    )
  }
}
```

**Inject a security header on every response:**

```ts
export function middleware(request: NextRequest) {
  const response = NextResponse.next()
  response.headers.set('X-Frame-Options', 'DENY')
  response.headers.set('X-Content-Type-Options', 'nosniff')
  return response
}
```

**Pass computed data to a route via a request header (middleware → Server Component):**

```ts
export function middleware(request: NextRequest) {
  const headers = new Headers(request.headers)
  headers.set('x-resolved-user-id', resolveUserId(request))
  return NextResponse.next({ request: { headers } })
}
```

Then in the Server Component: `headers().get('x-resolved-user-id')`.

### The matcher

The `config.matcher` array controls which paths execute the middleware. Paths not matched skip it entirely — critical for performance because static assets (`/_next/static/`, `/favicon.ico`) should never hit middleware.

```ts
export const config = {
  matcher: [
    // named capture: :path* = zero or more segments
    '/dashboard/:path*',
    // exclude static and image routes
    '/((?!_next/static|_next/image|favicon.ico).*)',
  ],
}
```

The second pattern is the canonical "everything except Next.js internals" matcher. The syntax is path-to-regexp — not a glob, not a regex literal, but the named-segment / wildcard syntax from Next.js routing.

> **Matcher strings are NOT regexes.** `'/(.*)'` means "any path." `'/dashboard/:path*'` means `/dashboard/` followed by zero or more segments. Writing a JS regex literal like `'^/api/.*$'` in the matcher compiles but may behave differently than you expect across runtimes.

---

## Edge runtime vs Node.js runtime

Middleware runs on the **edge runtime** by default. You can opt individual route segments into it too:

```ts
// app/api/geo/route.ts
export const runtime = 'edge'
```

The edge runtime is a V8 sandbox — it runs globally close to users, starts in microseconds, and has zero cold-start. The tradeoff: no Node.js built-ins.

| Available in edge | NOT available in edge |
|---|---|
| `fetch`, Web Crypto API, `URL`, `Headers` | `fs`, `path`, `crypto` (Node), `child_process` |
| `Request`, `Response`, `ReadableStream` | Most npm packages that import Node built-ins |
| `@vercel/edge`, geo/IP headers | Native addons (`.node` files) |
| Cookies, `Headers` manipulation | DNS lookups, raw TCP/UDP |

The most common surprise: **Prisma, pg, mysql2, and most ORMs do not work in the edge runtime** — they either import `net` or use native bindings. If your middleware needs to verify a session against a database, use a self-contained JWT or an HTTP call to an external service, not a direct DB query.

A useful heuristic: middleware that reads a cookie or header and makes a routing decision is edge-safe. Middleware that queries a database is not.

> `runtime = 'nodejs'` on an individual route segment opts it back into the full Node.js runtime while leaving other segments on edge. The two runtimes coexist in the same app.

---

## Debugging Streaming & Middleware

### Symptom → Cause → Fix

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| TTFB still slow even after adding Suspense | A top-level `await` in the layout or page component outside any boundary | Move the `await` inside a Server Component that lives inside a `<Suspense>`. Profile with `console.time` on the server to find the blocking fetch. |
| Fallback flashes and disappears immediately even on first load | Suspense boundary is inside a Client Component — the server can't stream past a client boundary | Move the Suspense to the nearest Server Component ancestor that wraps the async child. |
| Middleware runs on static assets, producing 401s | Matcher is too broad (`'/(.*)'`) | Add the Next.js static-exclusion pattern: `'/((?!_next/static|_next/image|favicon.ico).*)'` |
| A redirect loop: `/login` keeps redirecting to itself | Middleware redirects `/login` before checking if the current path *is* `/login` | Add a `pathname.startsWith('/login')` guard before the auth check. |
| `Error: The edge runtime does not support Node.js 'fs' module` | An import inside middleware (or a module it imports) pulls in a Node built-in | Audit the import chain. Use `next build`, then check `.next/server/middleware.js`. Extract the offending logic to a Node route handler. |
| Middleware runs but the rewrite doesn't take effect | Returning a rewrite to a path that itself matches the matcher triggers the middleware again | Either exclude the rewritten path from the matcher, or add an early-return guard for that internal path. |
| `headers()` in a Server Component returns `null` for a custom header set in middleware | Header name must be lowercase; must not collide with existing hop-by-hop headers | Always use an `x-` prefix for custom headers; read with `headers().get('x-your-header')`. |

### Finding a streaming waterfall

The browser DevTools Network tab shows TTFB and content chunks. For server-side profiling:

```ts
// in a Server Component
const t0 = performance.now()
const data = await fetch('https://slow-api.example.com/data', { cache: 'no-store' })
console.log(`[perf] slow-api: ${(performance.now() - t0).toFixed(0)}ms`)
```

Next.js dev server also logs fetch timings at the terminal. In production, add OpenTelemetry spans (covered in Module 07) for structured latency tracking.

### Debugging the matcher

Matcher mistakes are silent — the middleware just doesn't run. Add a log at the top of your middleware function to confirm it fires:

```ts
export function middleware(request: NextRequest) {
  console.log('[middleware]', request.method, request.nextUrl.pathname)
  // ...
}
```

Run `next dev` and check the terminal. If the log doesn't appear for a path you expected to match, the matcher is the problem — not your logic.

The fastest verification is a small test:

```ts
// match-test.ts — run with npx ts-node
import { match } from 'path-to-regexp'
const fn = match('/dashboard/:path*')
console.log(fn('/dashboard/settings'))  // should be truthy
console.log(fn('/api/users'))           // should be falsy
```

> **War story.** A middleware at my job was supposed to add a rate-limit header to every `/api/*` route. The matcher was `/api/:path+` — the `+` means *one or more segments*, so `/api/` (trailing slash, zero segments) never matched. The health-check endpoint lived at exactly `/api/` and was hammered by the load balancer, generating 40k unthrottled requests per minute. We spent three hours suspecting the rate-limit service itself before someone printed `request.nextUrl.pathname` in the middleware and saw what was actually arriving. The fix was changing `+` to `*`. Never assume the matcher hits what you think it hits — log the path until you've verified it in production.

---

## Checkpoint

You're ready for the challenges when you can answer these without looking:

1. Draw the streaming SSR lifecycle — from request to shell flush to incremental chunk. What resolves before the first byte leaves the server?
2. Why does a top-level `await` in a layout block the entire page even if the awaited data is only used in a sidebar?
3. What does `loading.tsx` compile to? Where does the Suspense boundary actually sit relative to the layout?
4. Name two things that are NOT available in the edge runtime and explain one alternative pattern for each.
5. Given a middleware that redirects unauthenticated users, how do you prevent a redirect loop on the `/login` route itself?
6. What does the matcher pattern `'/((?!_next/static|_next/image|favicon.ico).*)'` do, and why do you almost always need it?
7. A custom header you set in middleware is arriving as `null` in your Server Component. Name two things to check.
8. Describe the difference between a rewrite and a redirect in middleware, and give one use case for each.

➡ Next up: **Auth & Security** — protecting routes and Server Actions, cookies, CSRF, and the most common way to accidentally ship secrets to the client bundle.
