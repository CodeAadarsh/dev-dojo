# Auth & Security

> **Module 06 · Course 32** — Shipping an unprotected Server Action is the modern equivalent of leaving a `/admin/deleteAll` route with no auth check. The App Router moves security boundaries: they're no longer just at the network edge, they're inside your component tree and your action definitions. This module is about knowing exactly where those boundaries are, and defending each one.

The dangerous mental model to shed: "I protected the route, so the action is protected." Server Actions are separate HTTP endpoints. Middleware guards routes. Protecting one does not protect the other.

---

## Session vs JWT — the choice in a Next.js context

Both approaches are valid. The tradeoffs are different enough to matter at production scale.

```
┌──────────────────────────────────────┬────────────────────────────────────────┐
│  Server-side session                 │  Stateless JWT                         │
│  (iron-session, next-auth DB         │  (next-auth JWT strategy, jose,        │
│  adapter)                            │  custom)                               │
├──────────────────────────────────────┼────────────────────────────────────────┤
│  Cookie: opaque token → DB lookup    │  Cookie: signed JWT, verified locally  │
│  on every protected request          │  — no DB on each request               │
│                                      │                                        │
│  Can revoke instantly (delete row)   │  Cannot revoke before expiry without   │
│                                      │  a token blocklist (= the DB lookup    │
│                                      │  you were trying to avoid)             │
│                                      │                                        │
│  Cookie is small (~32 bytes)         │  JWT can grow large (claims, roles)    │
│                                      │  — cookie limit is 4 KB                │
│                                      │                                        │
│  Middleware: decode cookie → DB call │  Middleware: verify signature → read   │
│  (slow if not cached)                │  claims (fast, no I/O)                 │
│                                      │                                        │
│  Good for: admin panels, anything    │  Good for: stateless microservices,    │
│  requiring instant revocation        │  edge-first auth, CDN-side routing     │
└──────────────────────────────────────┴────────────────────────────────────────┘
```

For most Next.js apps, **use next-auth (Auth.js) with the JWT session strategy**. It handles the cookie, rotation, CSRF token, and provider integrations. The session payload is a signed+encrypted JWT inside an `HttpOnly` cookie — fast to verify in middleware, no database call on every request, and harder to tamper with than a plaintext cookie.

> **`iron-session` is the right choice when you want a simple encrypted cookie with zero framework.** Serialize any JSON into the cookie, sign it with a secret, done. It is not an auth framework — it doesn't manage OAuth or providers. Use it for session data when you're rolling your own auth logic.

---

## Protecting routes via middleware

The correct architecture: middleware reads the session cookie, verifies it (JWT signature check, or a fast cache hit), and redirects unauthenticated requests before they reach any Server Component.

```ts
// middleware.ts
import { NextRequest, NextResponse } from 'next/server'
import { getToken } from 'next-auth/jwt'

export async function middleware(request: NextRequest) {
  const token = await getToken({ req: request, secret: process.env.NEXTAUTH_SECRET })

  const isProtected = request.nextUrl.pathname.startsWith('/dashboard')
  if (isProtected && !token) {
    const loginUrl = new URL('/login', request.url)
    loginUrl.searchParams.set('callbackUrl', request.nextUrl.pathname)
    return NextResponse.redirect(loginUrl)
  }

  // RBAC: protect admin routes by role
  const isAdmin = request.nextUrl.pathname.startsWith('/admin')
  if (isAdmin && token?.role !== 'admin') {
    return NextResponse.redirect(new URL('/403', request.url))
  }
}

export const config = {
  matcher: ['/dashboard/:path*', '/admin/:path*'],
}
```

`getToken` verifies the JWT signature locally — no database call. This is why JWT sessions are preferred in middleware: the verification is CPU-only, takes under 1 ms, and works on the edge runtime.

---

## Protecting Server Actions

**Middleware does not protect Server Actions.** Server Actions POST to the same origin as their parent page but Next.js routes them through an internal endpoint (`/_next/action`), not through the page's URL path. A middleware redirect on `/dashboard` does nothing for a direct POST to the action.

Every Server Action that mutates data or reads private data must authenticate the caller inside the function body:

```ts
// lib/auth-guard.ts
import { auth } from '@/auth'   // Auth.js v5 / next-auth
import { redirect } from 'next/navigation'

export async function requireAuth() {
  const session = await auth()
  if (!session?.user) redirect('/login')
  return session
}

export async function requireRole(role: string) {
  const session = await requireAuth()
  if (session.user.role !== role) throw new Error('Forbidden')
  return session
}
```

```ts
// app/actions/delete-post.ts
'use server'
import { requireRole } from '@/lib/auth-guard'
import { z } from 'zod'

const Input = z.object({ postId: z.string().uuid() })

export async function deletePost(postId: string) {
  await requireRole('admin')                          // throws if not admin
  const { postId: id } = Input.parse({ postId })     // validate after auth
  await db.post.delete({ where: { id } })
}
```

The `'use server'` directive turns the function into an HTTP endpoint. If you do not check auth inside the body, any HTTP client can call it. The compiler does nothing to protect it.

> **Never trust the caller.** A Server Action receives the POST body deserialized — the arguments are not type-safe on the wire. Validate input with zod or equivalent *after* authenticating, not before. Auth first, then validate, then operate.

---

## Cookies & CSRF

### Cookie flags

For session cookies these three flags are non-negotiable:

| Flag | Effect | Missing means |
|------|--------|---------------|
| `HttpOnly` | JavaScript cannot read the cookie | `document.cookie` exposes the session token — XSS leads to session theft |
| `Secure` | Only sent over HTTPS | Session token travels in plaintext over HTTP |
| `SameSite=Lax` or `Strict` | Cookie not sent on cross-origin top-level requests (Lax = GET ok, Strict = never) | CSRF: a form on `attacker.com` can POST to your app and the browser includes the session cookie |

next-auth sets all three correctly by default. If you're rolling your own cookie, use `next/headers` `cookies()`:

```ts
import { cookies } from 'next/headers'

cookies().set('session', token, {
  httpOnly: true,
  secure: process.env.NODE_ENV === 'production',
  sameSite: 'lax',
  maxAge: 60 * 60 * 24 * 7,   // 7 days in seconds
  path: '/',
})
```

### CSRF with Server Actions

Next.js 14+ includes CSRF protection for Server Actions built-in: it validates the `Origin` header on action POSTs, rejecting cross-origin requests. This covers the primary CSRF vector — you do not need manual CSRF tokens for Server Actions.

**Route handlers (`app/api/*/route.ts`) are NOT covered.** They are plain HTTP endpoints — Next.js does not apply action CSRF checks to them. For a route handler that mutates state:

1. Require a custom `X-CSRF-Token` header (sent from your `fetch()` call, not forged by a cross-origin form submit).
2. Verify the `Origin` / `Referer` header matches your domain.
3. Use next-auth's `getCsrfToken()` flow.

The easy path: mutate via Server Actions, not route handlers, and get CSRF protection for free.

---

## Environment variables — the leakage map

This is the single most common security mistake in Next.js apps.

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Environment Variable Rules                                              │
│                                                                          │
│  NEXT_PUBLIC_STRIPE_PK=pk_live_xxx   ─►  bundled into client JS         │
│  NEXT_PUBLIC_API_URL=https://...     ─►  bundled into client JS         │
│                                                                          │
│  STRIPE_SECRET_KEY=sk_live_xxx       ─►  server only (never bundled)    │
│  DATABASE_URL=postgres://...         ─►  server only (never bundled)    │
│  NEXTAUTH_SECRET=...                 ─►  server only (never bundled)    │
│                                                                          │
│  Rule: NEXT_PUBLIC_ prefix = intentionally public.                      │
│        Everything else = private. Accessing a private env var in a      │
│        Client Component yields undefined at runtime, not a build error. │
└──────────────────────────────────────────────────────────────────────────┘
```

The insidious failure mode: you read `process.env.STRIPE_SECRET_KEY` in a utility function that is imported by both server and client code. The server side works fine. The client side gets `undefined` at runtime — no build error, no warning. The secret was never shipped to the browser... but the code path that handles `undefined` may silently break or fall back to something worse.

### The `server-only` package

Install `server-only` (zero dependencies) and import it in any module that must never run in the browser:

```ts
// lib/db.ts
import 'server-only'   // throws a build error if this module reaches a client bundle
import { PrismaClient } from '@prisma/client'

export const db = new PrismaClient()
```

The import causes a hard build error if the module is included in a client bundle, giving you a compile-time failure instead of a silent runtime bug. Use it in: database clients, secret-reading utilities, server-only business logic.

The pattern pairs with a directory convention: a `lib/server/` folder where every file imports `server-only` at the top. Any accidental client import blows up the build immediately.

---

## Secure headers

`next.config.js` supports a `headers()` function that injects HTTP headers on responses:

```js
// next.config.js
const securityHeaders = [
  { key: 'X-Frame-Options', value: 'DENY' },
  { key: 'X-Content-Type-Options', value: 'nosniff' },
  { key: 'Referrer-Policy', value: 'strict-origin-when-cross-origin' },
  {
    key: 'Content-Security-Policy',
    value: [
      "default-src 'self'",
      "script-src 'self' 'unsafe-inline'",   // tighten further with nonces if you can
      "style-src 'self' 'unsafe-inline'",
      "img-src 'self' data: https:",
      "font-src 'self'",
      "connect-src 'self' https://api.yourdomain.com",
    ].join('; '),
  },
  {
    key: 'Permissions-Policy',
    value: 'camera=(), microphone=(), geolocation=()',
  },
]

module.exports = {
  async headers() {
    return [{ source: '/(.*)', headers: securityHeaders }]
  },
}
```

Run your deployed site through [securityheaders.com](https://securityheaders.com) to grade the current state before and after.

**`Strict-Transport-Security`** (HSTS) should also be set here. Vercel adds it by default; for container deploys add it explicitly:

```js
{ key: 'Strict-Transport-Security', value: 'max-age=63072000; includeSubDomains; preload' }
```

---

## Debugging Auth & Security

### Symptom → Cause → Fix

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `process.env.STRIPE_SECRET_KEY` is `undefined` in a browser error | The variable was read inside a Client Component or a module imported by one | Move the secret read to a Server Component, Server Action, or route handler. Add `import 'server-only'` to the module. |
| Server Action is callable without auth by a raw `curl` | Auth check is missing inside the action body — middleware protection doesn't cover actions | Add `await requireAuth()` as the first line of every mutating action. |
| Cookie set in a Server Action is not sent on subsequent requests | Missing `path: '/'` — cookie is scoped to the action's internal URL path | Always pass `path: '/'` when setting cookies in actions. |
| User stays logged in after you delete their account | JWT session — there is no server-side revocation by default | Use a DB session adapter for revocable sessions, or maintain a token blocklist in Redis/Upstash. |
| Content-Security-Policy blocks a legitimate third-party script | The script's origin is not in `script-src` | Add the specific origin to `script-src`; use a nonce-based CSP for inline scripts to avoid `'unsafe-inline'`. |
| CSRF error on a legitimate form submission | A route handler (`/api/*/route.ts`) doesn't verify the request origin | Switch the mutation to a Server Action, or verify `request.headers.get('origin')` against your domain. |

### Finding a secret in the client bundle

Build the app, then search the static output:

```bash
npm run build
grep -r 'sk_live' .next/static/
grep -r 'STRIPE_SECRET' .next/static/
```

If anything matches, a secret is in the client bundle. Trace the import chain: which Client Component imports the module that reads the secret?

Next.js also warns during `next build` when a non-`NEXT_PUBLIC_` env var is accessed in client code. Watch for `Accessing process.env.X` warnings in the build output.

To audit systematically:

```bash
# list all env-var accesses in the client bundle
grep -o 'process\.env\.[A-Z_]*' .next/static/chunks/*.js | sort -u
```

Any variable that does not start with `NEXT_PUBLIC_` in that list is a potential bug or a secret leak.

> **War story.** A teammate shipped a dashboard analytics component that called a `getStats()` function. `getStats()` lived in `lib/analytics.ts`, which also imported `import { db } from './db'` — and `db.ts` read `process.env.DATABASE_URL`. The component was a Client Component because it used `useState` for a filter. The build succeeded; no runtime error. `DATABASE_URL` resolved to `undefined` on the client, so `getStats()` silently returned empty data. A week later, a security audit flagged that `lib/analytics.ts` was in the client bundle — and while the Postgres URL was `undefined` there, the same file also contained a hardcoded API key someone had committed as a "dev fallback." Adding `import 'server-only'` to `lib/analytics.ts` turned the silent bug into a build error that had to be fixed properly. The lesson: `server-only` is not just a security measure, it's a correctness guard. Use it in every module that has no business running in the browser.

---

## Checkpoint

1. Explain in one sentence why middleware protecting `/dashboard` does not protect a Server Action invoked from the dashboard.
2. What three cookie flags must a session cookie have, and what attack does each one defend against?
3. What is the difference between `NEXT_PUBLIC_STRIPE_PK` and `STRIPE_SECRET_KEY` from the build system's perspective? What happens at runtime if you read `STRIPE_SECRET_KEY` in a Client Component?
4. What does the `server-only` package do, and at what point does it throw?
5. Next.js provides CSRF protection automatically for Server Actions. Does the same protection apply to route handlers? What should you do instead?
6. You need to invalidate a JWT-based session immediately. Name the two valid approaches and explain the tradeoff of each.
7. Name the header that prevents your pages from being embedded in a cross-origin `<iframe>`, and give its maximum-restriction value.
8. Walk through the process of confirming a secret is NOT in the client bundle after a `next build`. Name the exact commands.

➡ Next up: **Performance & Deployment** — bundle analysis, `next/image`, caching headers, the standalone output, and shipping to Vercel or a container.
