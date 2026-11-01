# Server vs Client Components

> **Module 02 · Course 32** — "Just add `'use client'`" is the most common performance anti-pattern in Next.js apps. This module draws the RSC boundary precisely — what can and cannot cross it, how to compose across it, and how to audit a bundle for the damage over-clienting does.

You already know the difference exists. This module is about operating it deliberately: picking where to place the boundary, what composition patterns keep both sides clean, and how to enforce the rule so imports don't silently blow up your bundle.

---

## What runs where

Two environments, one component tree:

```
                BUILD / REQUEST TIME                   |  BROWSER
─────────────────────────────────────────────────────|───────────────────────────
Server Components                                     │  Client Components
  • Run on the server (build or request time)         │  • Run in the browser
  • Can be async; can await anything                  │  • Can use hooks, events
  • Direct DB / FS / env access                       │  • Can access window/DOM
  • Never shipped to the JS bundle                    │  • Shipped in the bundle
  • Render → RSC payload                              │  • Hydrated from RSC payload
                                                      │
  <Page>                                              │
    <UserCard user={user} />    ◄── SC: zero JS cost  │
      <LikeButton />            ◄── CC: interactive   │
    <Comments />                ◄── SC: DB read       │
      <CommentForm />           ◄── CC: form state    │
```

The default in `app/` is Server Component. Every file without `'use client'` is a Server Component (or shared — if it uses neither server-only APIs nor client-only APIs, it runs in whichever environment imports it).

---

## The serialization boundary

When a Server Component renders a Client Component, it passes props across the RSC boundary. Those props must be serializable to the RSC wire protocol:

**Can cross the boundary:**
- Primitives: string, number, boolean, null, undefined
- Plain objects and arrays (recursively serializable)
- `Date` (serialized to ISO string and rehydrated)
- `Promise` (streamed — the client receives the resolved value)
- Server Actions (an opaque reference handled by the framework)

**Cannot cross the boundary:**
- Functions (except Server Actions)
- Class instances
- React elements that are Server Components (they're rendered server-side before passing)
- Symbols
- Circular references

The runtime error `Functions cannot be passed directly to Client Components unless you explicitly expose it using the "use server" directive` fires when you break this rule.

The subtler violation is passing an ORM model instance:

```tsx
// Bad — Prisma model instance is not a plain object
const user = await prisma.user.findUnique({ where: { id } })
return <ProfileEditor user={user} />     // may fail or silently drop methods

// Good — destructure to a plain serializable shape
return <ProfileEditor user={{ id: user.id, name: user.name, email: user.email }} />
```

When in doubt, `JSON.parse(JSON.stringify(obj))` is the quick escape hatch to strip class identity. For production code, define a plain DTO type and select exactly those fields from the ORM.

---

## When to add `'use client'`

Add `'use client'` when the component needs:

- React hooks (`useState`, `useEffect`, `useRef`, `useContext`, `useReducer`)
- Browser APIs (`window`, `document`, `localStorage`, `navigator`)
- Event handlers that close over local state or call browser APIs
- Third-party libraries that use any of the above

Do **not** add `'use client'` for:
- Components that are purely presentational and receive all data as props
- Components that just pass `children` through
- Components that need async data — use a Server Component instead

The heuristic: **`'use client'` marks an entry point into the client bundle, not a "this component runs in the browser" flag.** Once you mark a file, the entire import graph below it becomes client-side JavaScript. That's why placement matters. Push `'use client'` to the leaf components that actually need interactivity, not to the tree roots.

```
Before (bad — entire dashboard is client JS):      After (good — only interactive parts):

app/dashboard/page.tsx  ← 'use client'            app/dashboard/page.tsx  ← Server Component
  └── <DashboardShell>                               └── <DashboardShell>  ← Server Component
       ├── <StatCards />                                  ├── <StatCards />   ← Server (DB read)
       └── <ChartSection>                                 └── <ChartSection> ← Server Component
            └── <Chart />                                      └── <Chart /> ← 'use client'
```

In the "before" tree, Prisma, the full chart library, and all utility imports get bundled for the browser. In the "after" tree, only `<Chart />` and its direct dependencies are in the client bundle.

---

## Passing server data to client

The pattern: Server Component fetches, Client Component interacts.

```tsx
// app/dashboard/page.tsx — Server Component
import { ChartClient } from '@/components/chart-client'

export default async function DashboardPage() {
  const metrics = await db.metric.findMany({
    where: { date: { gte: thirtyDaysAgo() } },
    orderBy: { date: 'asc' },
    select: { date: true, value: true },  // plain scalars — serializable
  })
  return <ChartClient data={metrics} />
}
```

```tsx
// components/chart-client.tsx
'use client'
import { useState } from 'react'
import { LineChart, Line, XAxis, YAxis } from 'recharts'

type Metric = { date: string; value: number }

export function ChartClient({ data }: { data: Metric[] }) {
  const [range, setRange] = useState<'7d' | '30d'>('30d')
  const filtered = data.filter(m => range === '30d' || isWithin7Days(m.date))
  return (
    <>
      <RangeToggle value={range} onChange={setRange} />
      <LineChart data={filtered} width={600} height={300}>
        <XAxis dataKey="date" />
        <YAxis />
        <Line type="monotone" dataKey="value" />
      </LineChart>
    </>
  )
}
```

The data arrives as serialized RSC payload and is handed to the Client Component as initial props. The chart library ships to the browser; the DB call does not.

---

## Composition patterns

### Pattern 1: Children as slots

A Client Component can receive Server Components as `children` — because children are rendered server-side before being passed:

```tsx
// components/modal.tsx — Client Component managing open state
'use client'
import { useState } from 'react'

export function Modal({ trigger, children }: { trigger: React.ReactNode; children: React.ReactNode }) {
  const [open, setOpen] = useState(false)
  return (
    <>
      <div onClick={() => setOpen(true)}>{trigger}</div>
      {open && (
        <div className="fixed inset-0 flex items-center justify-center bg-black/50">
          <div className="bg-white rounded-lg p-6">{children}</div>
        </div>
      )}
    </>
  )
}

// app/users/page.tsx — Server Component composing Modal with SC children
import { Modal } from '@/components/modal'
import { UserDetails } from '@/components/user-details'  // Server Component

export default async function Page() {
  const user = await getUser()
  return (
    <Modal trigger={<button>View details</button>}>
      <UserDetails user={user} />   {/* rendered server-side, passed as children */}
    </Modal>
  )
}
```

`UserDetails` runs on the server and DB-fetches freely. `Modal` manages open state on the client. Neither knows about the other's environment — the composition point is `children`, which is already rendered RSC output by the time `Modal` receives it.

### Pattern 2: Passing Server Actions as props

Server Actions are the one type of function that can cross the RSC boundary:

```tsx
// app/comments/page.tsx — Server Component
import { CommentForm } from '@/components/comment-form'
import { createComment } from '@/app/actions/comments'   // 'use server'

export default async function CommentsPage() {
  return <CommentForm action={createComment} />
}
```

```tsx
// components/comment-form.tsx — Client Component
'use client'

type CommentAction = (fd: FormData) => Promise<void>

export function CommentForm({ action }: { action: CommentAction }) {
  return (
    <form action={action}>
      <textarea name="body" required />
      <button type="submit">Post</button>
    </form>
  )
}
```

The `action` prop is a Server Action reference — an opaque handle the framework manages. The Client Component treats it like any function prop.

### Pattern 3: Context providers at the boundary

Context only works in Client Components. Put the provider as high as needed, but no higher:

```tsx
// components/providers.tsx — thin Client Component wrapper
'use client'
import { ThemeProvider } from 'next-themes'

export function Providers({ children }: { children: React.ReactNode }) {
  return <ThemeProvider attribute="class">{children}</ThemeProvider>
}

// app/layout.tsx — root layout stays Server Component
import { Providers } from '@/components/providers'

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>
        <Providers>{children}</Providers>
      </body>
    </html>
  )
}
```

`RootLayout` is still a Server Component. `Providers` is the only Client Component here, and `children` (the entire page tree) is rendered server-side and passed into it. This pattern is what makes "wrap the whole app in providers" compatible with RSC.

---

## Keeping secrets server-side

The App Router's compiler enforces a hard rule: any file imported into a Client Component is bundled for the browser. Environment variables not prefixed `NEXT_PUBLIC_` are never inlined into client bundles — but only if you never import them into a Client Component.

The `server-only` package makes violations a compile error:

```bash
npm install server-only
```

```ts
// lib/db.ts — database client, never goes to the browser
import 'server-only'

import { drizzle } from 'drizzle-orm/libsql'
import { createClient } from '@libsql/client'

export const db = drizzle(createClient({
  url: process.env.TURSO_URL!,        // NOT NEXT_PUBLIC_ → server only
  authToken: process.env.TURSO_TOKEN!,
}))
```

```ts
// lib/auth.ts — session read, never goes to the browser
import 'server-only'
import { cookies } from 'next/headers'
import { verifyJwt } from './jwt'

export async function getSession() {
  const cookieStore = await cookies()
  const token = cookieStore.get('session')?.value
  if (!token) return null
  return verifyJwt(token)
}
```

If any developer accidentally imports `db` into a Client Component, the build fails with a clear error instead of silently shipping the DB URL to every browser that loads the app.

---

## Debugging Server vs Client Components

### Symptom → cause → fix

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `Functions cannot be passed directly to Client Components` | Passing a plain function from SC to CC as a prop | Move the function into the CC, or mark it `'use server'` if it's a mutation |
| `You're importing a component that needs … It only works in a Client Component but none of its parents are marked with "use client"` | Using a hook in a Server Component | Add `'use client'` to the component that uses the hook |
| DB credentials appear in browser network payloads | Server-only module imported (directly or transitively) by a CC | Add `import 'server-only'` to the module; trace the import chain |
| `window is not defined` at runtime | Browser API called at render time in a Server Component or without `useEffect` guard | Guard with `typeof window !== 'undefined'` or move to `useEffect` in a CC |
| Bundle size jumped after adding a feature | `'use client'` placed too high in the tree | Move `'use client'` to the leaf component; audit with `@next/bundle-analyzer` |

### Diagnosing bundle bloat from over-clienting

`next build` outputs a route summary. Flag any route with First Load JS over ~100 kB when it should be mostly static:

```
Route (app)               Size     First Load JS
┌ ○ /                     3.42 kB        92.3 kB
├ ○ /dashboard           48.2 kB        212 kB   ← suspicious
└ ○ /blog/[slug]          1.87 kB        81.4 kB
```

Install `@next/bundle-analyzer` to trace what's in the 212 kB:

```bash
npm install --save-dev @next/bundle-analyzer
```

```ts
// next.config.ts
import withBundleAnalyzer from '@next/bundle-analyzer'
export default withBundleAnalyzer({ enabled: process.env.ANALYZE === 'true' })({})
```

```bash
ANALYZE=true npm run build
# Opens two interactive treemaps: server bundle and client bundle
```

In the client treemap, look for:
- Libraries that only belong on the server (drizzle-orm, Prisma, node:crypto, node:fs)
- Large visualization libraries pulled in by a component that could be SSR'd
- Duplicate copies of the same library at different semver resolutions (hoisting failure)

### Diagnosing "importing server code into client"

The violation is usually indirect — a utility that was safe to import everywhere, until someone added a server-only import to it.

Trace the import chain manually:

```bash
# All files importing the DB module
grep -r "from '@/lib/db'" --include="*.tsx" --include="*.ts" .

# Which of those have 'use client' or are reachable from a 'use client' file
grep -l "'use client'" $(grep -rl "from '@/lib/db'" --include="*.tsx" .)
```

If you find a Client Component in the output, the fix is one of:

1. Move the data-fetching logic to a Server Component parent and pass data as props.
2. Convert to a Server Action called from the Client Component.
3. Add `import 'server-only'` to `@/lib/db` to make any future violation a build error instead of a silent bundle bloat.

> **War story.** We added a `formatCurrency` utility to `@/lib/format` — a pure function, no imports. Then added an i18n locale lookup to it (`import { getLocale } from '@/lib/i18n'`), and `@/lib/i18n` imported `@/lib/auth` for the user's locale preference, and `@/lib/auth` imported `@/lib/db`. Three hops later, the entire Drizzle client appeared in the client bundle. Bundle analysis showed a 340 kB jump. The fix was `import 'server-only'` on `@/lib/db` (instant build error on next touch), extracting the locale fetch to a Server Component prop, and keeping `formatCurrency` as a pure function that accepts locale as a parameter. The lesson: import chains are silent killers. `server-only` is your circuit breaker — add it the moment a file touches infrastructure.

---

## Checkpoint

You're ready for the challenges when you can, without looking anything up:

1. Recite the exact rule: what can and cannot cross the RSC serialization boundary.
2. Explain why `'use client'` is an entry point, not a per-component flag, and why placement in the tree determines bundle size.
3. Implement the children-as-slots pattern: a Client Component managing `open` state, rendering Server Component children passed as a prop.
4. Pass a Server Action as a prop to a Client Component form without wrapping it in an anonymous function.
5. Add `import 'server-only'` to a module and explain what happens at build time if a Client Component imports it.
6. Use `@next/bundle-analyzer` to diagnose a 200 kB bundle increase and identify the mis-placed `'use client'`.
7. Trace an accidental import of a server-only DB client through three hops of utility functions using `grep`.
8. Set up a `Providers` wrapper Client Component in the root layout so that `RootLayout` itself remains a Server Component.

➡ Next up: **Data Fetching & Caching** — the fetch cache, revalidation strategies, PPR, and debugging stale data in production.
