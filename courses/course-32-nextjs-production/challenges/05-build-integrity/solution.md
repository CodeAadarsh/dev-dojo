# Solution: Build Integrity

## The bug

`app/dashboard/page.tsx` has `"use client"` at the top **and** imports `ServerData` from `@/components/ServerData.tsx`. `ServerData` contains `import "server-only"` — a package that throws a build-time error if it is ever bundled into a Client Component.

```
Error: This module cannot be imported from a Client Component module.
It should only be used from a Server Component.
```

## Two valid fixes

### Fix A — remove `"use client"` from the dashboard page (preferred)

The `DashboardPage` component uses no client APIs (`useState`, `useEffect`, browser APIs). The `"use client"` directive was added by mistake. Removing it makes the component a Server Component again, which is allowed to import server-only modules.

```typescript
// app/dashboard/page.tsx — fixed
import { ServerData } from "@/components/ServerData";

export default function DashboardPage() {
  return (
    <section>
      <h1>Dashboard</h1>
      <ServerData />
    </section>
  );
}
```

### Fix B — stop importing `ServerData` from a Client Component

If the page genuinely needs client interactivity (e.g., `useState`), move `<ServerData />` out of it. Fetch the data server-side and pass it as a prop, or split the component tree so the server-only part lives in a Server Component parent.

```typescript
// app/dashboard/page.tsx — stays client
"use client";

export default function DashboardPage({ serverTimestamp }: { serverTimestamp: string }) {
  return (
    <section>
      <h1>Dashboard</h1>
      <p>Server time: {serverTimestamp}</p>
    </section>
  );
}

// app/dashboard/layout.tsx — Server Component wraps the Client Component
import { ServerData } from "@/components/ServerData";
import DashboardPage from "./page";

export default function DashboardLayout() {
  // pass server data down as props, never import server-only into the client
  return <DashboardPage serverTimestamp={new Date().toISOString()} />;
}
```

## Why `server-only` exists

React Server Components split the module graph into two worlds: the server graph (can use `fs`, `headers()`, secrets) and the client graph (ships to the browser). The `server-only` package enforces this boundary at **build time** rather than at runtime, giving you an immediate, obvious error instead of a silent data leak that ships server secrets to the browser bundle.

The companion package `client-only` does the reverse — it prevents a browser-only module (e.g., one that uses `window`) from accidentally running in an SSR context.

## Debugging `next build` errors

Always start here:

```bash
npx next build 2>&1 | head -80
```

Next.js emits the **root cause** first, then a cascade of import-chain failures. The first `Error:` block is almost always the one to fix. Once you fix the root cause, all the downstream "could not resolve" or "module boundary" errors disappear.

For type errors specifically, run:

```bash
npx tsc --noEmit
```

This runs the TypeScript compiler without emitting JS — faster than a full build for catching type mistakes.
