# The App Router

> **Module 01 · Course 32** — The App Router is not a routing library — it's an execution environment with opinions baked into the file system. You've used it if you've scaffolded a Next.js 13+ app, but most teams use only a fraction of what it gives you. This module goes all the way down.

You already build with Next.js. This is deliberately fast on "add a `page.tsx`" and slow on the parts that bite at scale: why layouts survive navigation, how RSC changes what runs where, and what the file conventions actually guarantee.

---

## The file-convention contract

The App Router maps the file system to a hierarchy of React trees. The conventions are not just naming sugar — each filename hooks into a specific rendering slot in the framework.

```
app/
  layout.tsx          ← root layout, always rendered, wraps everything
  page.tsx            ← UI for the "/" route
  loading.tsx         ← Suspense boundary; React streams this while page data loads
  error.tsx           ← 'use client' error boundary; catches runtime errors below it
  not-found.tsx       ← rendered when notFound() is called or no route matches
  global-error.tsx    ← catches errors in the root layout itself (rare but important)
  route.ts            ← API route handler; turns a directory into an HTTP endpoint
  template.tsx        ← like layout but re-mounts on every navigation (rare)
  default.tsx         ← fallback for parallel route slots when no match
```

The critical distinction:

| File | Re-renders on navigation? | Can be async? | Wraps what |
|------|--------------------------|---------------|------------|
| `layout.tsx` | **No** — persists across child navigations | Yes (Server Component) | its subtree |
| `template.tsx` | Yes — full remount | Yes | its subtree |
| `page.tsx` | Yes | Yes (Server Component) | nothing (leaf) |
| `loading.tsx` | Yes | No (synchronous) | the page boundary it wraps |
| `error.tsx` | Yes | No (must be `'use client'`) | the component below the layout |
| `route.ts` | N/A — not UI | Yes | N/A |

`loading.tsx` is syntactic sugar for wrapping `page.tsx` in `<Suspense fallback={<YourLoading />}>`. The framework does the wrapping — you just provide the fallback UI. This means streaming works automatically when `page.tsx` is async: the shell (layout + loading) ships on the first byte, and the page content streams in when the data is ready.

`error.tsx` **must be `'use client'`** because error boundaries are a React feature that requires class lifecycle methods (or their function-equivalent hooks) — things that only exist in Client Components. The boundary catches throws in components *below* the layout at its level, but not in the layout itself. That's what `global-error.tsx` is for.

---

## RSC by default

Every file in `app/` is a Server Component unless you write `'use client'` at the top. Server Components run **on the server** — at request time for dynamic routes, at build time for static ones. They have direct access to the file system, databases, and secrets.

```
Request
   │
   ▼
Next.js server
   │  resolves the route, renders the Server Component tree
   │  → may await data fetches, read fs, call DB
   │
   ▼
RSC payload (React Server Component wire protocol — not HTML, not JSON)
   │
   ▼
Browser
   ├── streamed HTML for the initial paint
   └── RSC payload to hydrate the React tree
       (Client Components rehydrate; Server Components become static HTML nodes)
```

What this changes in practice:

- **Zero bundle cost for server-only logic.** An `async function Page()` that `await`s a DB call ships *no JavaScript* for that fetch to the client. The client gets the rendered result, not the code.
- **No prop-drilling for auth context through the server layer.** An auth cookie read in a layout can be passed as props through Server Components all the way to the leaf — no Context needed for the server layer.
- **The boundary matters.** Once you add `'use client'` to a component, it and *all of its imports* become part of the client bundle. A Server Component can import a Client Component freely; a Client Component cannot import a Server Component.

---

## Nested layouts

Layouts nest. Each `layout.tsx` along the route path wraps the next:

```
app/
  layout.tsx              ← root layout (html, body, providers)
  dashboard/
    layout.tsx            ← dashboard layout (sidebar, nav)
    page.tsx              ← /dashboard
    settings/
      layout.tsx          ← settings layout (tab nav)
      page.tsx            ← /dashboard/settings
```

Navigating from `/dashboard` to `/dashboard/settings`:

- The root layout **does not remount** — the `<html>` and `<body>` stay.
- The dashboard layout **does not remount** — the sidebar stays, scroll position is preserved.
- Only the settings layout and its `page.tsx` are fetched and swapped in.

This is the layout persistence model. It's what makes client-side navigation in Next.js feel instantaneous. The cost: **a layout cannot react to its child segment changing** without opt-in. If a sidebar needs to highlight the active route, use `usePathname()` in a Client Component inside the layout — layouts don't re-render on navigation, but client hooks inside them do run.

```tsx
// app/dashboard/layout.tsx — sidebar highlights active route
import { Sidebar } from '@/components/sidebar' // Sidebar is 'use client'

export default function DashboardLayout({ children }: { children: React.ReactNode }) {
  return (
    <div className="flex h-screen">
      <Sidebar />          {/* re-renders on nav; reads usePathname() internally */}
      <main className="flex-1 overflow-y-auto">{children}</main>
    </div>
  )
}
```

---

## Route groups & dynamic segments

**Route groups** `(name)` let you organize files without affecting the URL:

```
app/
  (marketing)/
    layout.tsx          ← marketing shell (no nav, no auth)
    page.tsx            ← /
    about/
      page.tsx          ← /about
  (app)/
    layout.tsx          ← app shell (nav + auth guard)
    dashboard/
      page.tsx          ← /dashboard
    settings/
      page.tsx          ← /settings
```

The `(marketing)` and `(app)` folders are invisible to the URL — `/dashboard` is still `/dashboard`. But they let you apply *different root layouts* to different parts of the app without a single monolithic `layout.tsx`. This is the idiomatic pattern for a marketing shell (minimal, no auth) and an app shell (nav, sidebar, auth guard) coexisting in one project.

**Dynamic segments** `[param]` and **catch-all segments** `[...slug]` are the parametric route mechanism:

```
app/
  blog/
    [slug]/
      page.tsx          ← /blog/anything, params.slug = "anything"
  docs/
    [...path]/
      page.tsx          ← /docs/a/b/c, params.path = ["a","b","c"]
  [[...optional]]/
    page.tsx            ← optional catch-all; also matches the parent route itself
```

In a Server Component page, params arrive as a prop (a `Promise` in Next.js 15+):

```tsx
// app/blog/[slug]/page.tsx
type Props = { params: Promise<{ slug: string }> }

export default async function BlogPost({ params }: Props) {
  const { slug } = await params
  const post = await db.post.findUnique({ where: { slug } })
  if (!post) notFound()
  return <article>{post.body}</article>
}

// Static generation: tell Next.js which slugs to pre-render at build time
export async function generateStaticParams() {
  const posts = await db.post.findMany({ select: { slug: true } })
  return posts.map(p => ({ slug: p.slug }))
}
```

`generateStaticParams` is the App Router equivalent of `getStaticPaths`. Return an array of param objects and those routes are pre-rendered at build time. Any slug not in the list is either 404'd or rendered on demand depending on `dynamicParams` (default `true` in Next.js 14+).

---

## Metadata

Next.js has a typed metadata system that generates `<head>` tags without a custom `<Head>` component. Two forms — static and dynamic:

```tsx
// app/page.tsx — static metadata
import type { Metadata } from 'next'

export const metadata: Metadata = {
  title: 'Home',
  description: 'My app home page',
  openGraph: {
    title: 'Home',
    images: [{ url: '/og/home.png', width: 1200, height: 630 }],
  },
}
```

```tsx
// app/blog/[slug]/page.tsx — dynamic metadata
export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const { slug } = await params
  const post = await db.post.findUnique({ where: { slug }, select: { title: true, excerpt: true } })
  if (!post) return { title: 'Not found' }
  return {
    title: post.title,
    description: post.excerpt,
  }
}
```

`generateMetadata` shares the data fetch with the page component via request memoization — if both call `getPost(slug)` backed by React's `cache()`, the DB is only queried once per request.

Child segment metadata **merges** with the parent's, with child values overriding parent values for the same key. The root layout's metadata is your site-wide defaults.

---

## Debugging the App Router

Routing bugs in the App Router usually fall into three categories: a wrong assumption about what re-renders, a missing `'use client'` that breaks hydration, or a layout you expect to update that doesn't.

### Symptom → cause → fix

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `Error: Hydration failed because the server rendered HTML didn't match the client` | Component renders different output server vs client (date, random, window access) | Extract the client-only part into a `'use client'` component; initialize with `useEffect` or `useState(null)` |
| `Functions cannot be passed directly to Client Components unless you explicitly expose it using the "use server" directive` | Passing an arrow function defined in a Server Component as a prop to a Client Component | Move the handler into the Client Component, or mark it `'use server'` if it's a Server Action |
| Layout shows stale UI after navigating (sidebar not updating active link) | Layout does not re-render on navigation — correct behavior | Move reactive parts of the layout into `'use client'` children that read `usePathname()` or `useSelectedLayoutSegment()` |
| `page.tsx` renders but without the layout | `layout.tsx` is misnamed or at the wrong level | Confirm `layout.tsx` exists at or above the segment folder and the filename is exact (case-sensitive on Linux deploys) |
| `error.tsx` not catching errors | `error.tsx` only catches errors in components rendered *below* the layout at its level, not the layout itself | Add `global-error.tsx` at the same level, or wrap the layout's dynamic part in a nested layout |

### Diagnosing hydration mismatches

Hydration mismatches are the most common App Router bug and the most confusing error message. The browser console shows a diff between what the server sent and what React rendered client-side.

**1. Date/time rendering.** `new Date().toLocaleDateString()` in a Server Component runs at request time. The exact same call during client hydration runs milliseconds later and may differ in locale.

```tsx
// Bad — different output server vs client
export default function Footer() {
  return <p>Last updated: {new Date().toLocaleDateString()}</p>
}

// Good — locale-sensitive formatting belongs in a 'use client' component
'use client'
export function LastUpdated({ iso }: { iso: string }) {
  return <time>{new Date(iso).toLocaleDateString()}</time>
}
```

**2. `typeof window` or browser-only globals.** Code that reads `window`, `document`, or `localStorage` is a hydration bomb if it runs outside `useEffect`.

```tsx
'use client'
import { useState, useEffect } from 'react'

export function ThemeToggle() {
  const [theme, setTheme] = useState<string | null>(null)  // null on server pass

  useEffect(() => {
    setTheme(localStorage.getItem('theme') ?? 'light')
  }, [])

  if (!theme) return null   // skip render until client has hydrated cleanly
  return <button onClick={() => setTheme(t => t === 'light' ? 'dark' : 'light')}>{theme}</button>
}
```

**3. Third-party libraries that access `window` at import time.** Dynamic-import with `{ ssr: false }`:

```tsx
import dynamic from 'next/dynamic'
const RichEditor = dynamic(() => import('@/components/rich-editor'), { ssr: false })
```

### Diagnosing layout not re-rendering

If a Server Component layout reads a cookie or header and the UI doesn't update after a mutation without a full page reload, you've hit layout persistence:

```tsx
// app/dashboard/layout.tsx
import { cookies } from 'next/headers'

export default async function DashboardLayout({ children }) {
  const cookieStore = await cookies()
  const org = cookieStore.get('activeOrg')?.value
  // ← Runs at request time. Does NOT re-run on client-side navigation.
  return <div data-org={org}>{children}</div>
}
```

To have the layout react to a cookie change without a full reload, move the reactive read into a `'use client'` component. Two patterns:

```tsx
// Option A: read via a thin Client Component using document.cookie or a cookie library
'use client'
import Cookies from 'js-cookie'
export function OrgDisplay() {
  const [org, setOrg] = useState(Cookies.get('activeOrg'))
  // subscribe to cookie changes via custom event from Server Action callback
  return <span>{org}</span>
}

// Option B: Server Action returns the new value; caller updates local state
export async function switchOrg(orgId: string) {
  'use server'
  // set the cookie, revalidate
  return { newOrgName: await getOrgName(orgId) }   // return value reaches the client
}
```

> **War story.** We had a dashboard where the active-org selector lived in the root layout. It read `orgId` from a session cookie via `cookies()`. After switching org via a Server Action, the sidebar kept showing the old org name. The action called `revalidatePath('/')`, which invalidated the page cache — but on *client navigation*, the layout doesn't re-request. The fix was splitting the org display into a `'use client'` component that read from a Jotai atom, with the Server Action returning the new org name as a return value that the client updated the atom with. The layout render path was correct; our mental model of "layout re-runs on mutation" was wrong. Layout persistence is a feature — it keeps the sidebar scroll position stable — but you have to design around it explicitly.

---

## Checkpoint

You're ready for the challenges when you can, without looking anything up:

1. Name all six special files in `app/` and what each one does (layout, page, loading, error, route, not-found).
2. Explain why `error.tsx` must be `'use client'` and what catches errors thrown inside the root layout.
3. Draw the component tree for a three-level nested route and identify which layouts remount on navigation and which do not.
4. Create a route group structure that applies different root layouts to `/` (marketing) and `/dashboard` (app shell) without URL changes.
5. Write a `generateStaticParams` export for a `[slug]` route that pre-renders the 50 most recent blog posts.
6. Diagnose a hydration mismatch caused by `Date` formatting and fix it without adding `'use client'` to the page itself.
7. Explain why a layout that reads a cookie may show stale data after a Server Action mutation, and describe two fixes.
8. Use `useSelectedLayoutSegment()` to highlight the active tab in a dashboard layout without triggering a layout remount.

➡ Next up: **Server vs Client Components** — the serialization boundary in depth, composition patterns, and keeping secrets off the wire.
