# Performance & Deployment

> **Module 07 · Course 32** — A Next.js app that works is not the same as one that scores 95+ on Core Web Vitals and costs nothing to run. The last 20% of perf work — bundle analysis, font loading, image sizing, caching headers, and a reproducible container build — is where the gap between intermediate and senior shows most clearly.

By the end of this module you'll have a reproducible Docker image, a caching strategy that's not just `revalidate: 60` on everything, and the habit of running `@next/bundle-analyzer` before any PR that adds a significant import.

---

## Bundle analysis — measure before you optimize

### `@next/bundle-analyzer`

```bash
npm install --save-dev @next/bundle-analyzer
```

```js
// next.config.js
const withBundleAnalyzer = require('@next/bundle-analyzer')({
  enabled: process.env.ANALYZE === 'true',
})
module.exports = withBundleAnalyzer({ /* your existing config */ })
```

```bash
ANALYZE=true npm run build
```

This opens two treemap visualizations in your browser: the server bundle and the client bundle. The client bundle is what users download — optimize it first. The server bundle matters for cold-start time on Lambda/edge functions and for memory footprint.

**What to look for in the client treemap:**

- A single library consuming > 20% of the total (lodash, moment, `date-fns` if imported as `*`)
- Duplicate packages — two versions of the same library in separate chunks
- Server-only code in the client treemap (a sign `server-only` should be applied)

### Tree-shaking and named imports

```ts
// Bad — pulls in the entire lodash bundle (~70 KB gzipped)
import _ from 'lodash'
const sorted = _.sortBy(items, 'name')

// Good — cherry-picks only the sortBy module (~5 KB)
import sortBy from 'lodash/sortBy'

// Also good if you're on lodash-es (true ESM, tree-shakes with named imports)
import { sortBy } from 'lodash-es'
```

`lodash` (CommonJS) does not tree-shake regardless of the import style — the module graph is opaque to the bundler. `lodash-es` and `date-fns` are ESM and tree-shake correctly with named imports.

### Dynamic imports for code splitting

Routes are already split by Next.js — each page is its own chunk. But within a page, large components (rich text editors, charting libraries, PDF renderers) should be dynamically imported so they don't inflate the initial chunk:

```ts
import dynamic from 'next/dynamic'

const RichEditor = dynamic(() => import('@/components/RichEditor'), {
  loading: () => <div>Loading editor...</div>,
  ssr: false,   // skip SSR for components that require window/document
})
```

`ssr: false` skips server rendering entirely for this component — the HTML won't contain it, and it loads only after hydration. Use it only when the component requires browser-only APIs and cannot be made SSR-safe.

---

## `next/image` — the right way to handle images

### Why it matters

Images are the leading cause of layout shift (CLS) and LCP regressions. Raw `<img>` tags have no intrinsic size until the image loads — the browser can't reserve space, and the layout shifts when it arrives. `next/image`:

- Prevents CLS by requiring `width`/`height` (or `fill`)
- Serves WebP/AVIF automatically (smaller files, same visual quality)
- Lazy loads by default (only LCP images above the fold should be `priority`)
- Resizes on-the-fly via the built-in Image Optimization API

```tsx
import Image from 'next/image'

// Fixed size — use when the image has known pixel dimensions
<Image
  src="/hero.png"
  alt="Hero"
  width={1200}
  height={630}
  priority          // load eagerly — only for the page's LCP image
/>

// Fill container — use for responsive / unknown-dimension images
<div className="relative h-64 w-full">
  <Image
    src={user.avatarUrl}
    alt={user.name}
    fill
    sizes="(max-width: 768px) 100vw, 33vw"
    className="object-cover"
  />
</div>
```

**The `sizes` attribute is not optional when using `fill` or responsive sizing.** Without it, Next.js can't generate the right `srcset` and will serve a full-resolution image at every breakpoint. `sizes` tells the optimizer what fraction of the viewport the image occupies at each breakpoint so it can build a correctly-sized `srcset`.

### External image domains

```js
// next.config.js — must allowlist external image hostnames
module.exports = {
  images: {
    remotePatterns: [
      { protocol: 'https', hostname: 'cdn.example.com', pathname: '/images/**' },
      { protocol: 'https', hostname: '**.cloudfront.net' },
    ],
  },
}
```

A missing `remotePatterns` entry causes Next.js to return a 400 for the optimized image URL — a common deploy-day surprise when the domain differs between environments.

---

## `next/font` — zero layout shift for web fonts

Loading a web font with a plain `<link>` introduces a Flash Of Invisible Text (FOIT) or Flash Of Unstyled Text (FOUT), both of which contribute to CLS. `next/font` eliminates this by:

1. Downloading font files at build time (not at runtime from Google Fonts).
2. Self-hosting them in `_next/static/`.
3. Adding `size-adjust` and `ascent-override` CSS to a local fallback font that matches the web font's metrics — so the layout doesn't shift when the real font loads.

```ts
// app/layout.tsx
import { Inter, JetBrains_Mono } from 'next/font/google'

const inter = Inter({
  subsets: ['latin'],
  display: 'swap',
  variable: '--font-sans',
})

const mono = JetBrains_Mono({
  subsets: ['latin'],
  display: 'swap',
  variable: '--font-mono',
})

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className={`${inter.variable} ${mono.variable}`}>
      <body>{children}</body>
    </html>
  )
}
```

Using CSS variables (`variable: '--font-sans'`) instead of `className` lets you reference the font in Tailwind and global CSS:

```css
/* globals.css */
body { font-family: var(--font-sans), system-ui, sans-serif; }
code { font-family: var(--font-mono), monospace; }
```

Remove any existing `<link>` Google Fonts tag from your `<head>` — mixing `next/font` and a raw `<link>` results in a duplicate download and defeats the CLS protection.

---

## Caching headers and ISR

### The four caching layers

```
┌─────────────────────────────────────────────────────────────────────┐
│  1. Request Memoization — deduplicates fetch() calls within a       │
│                           single render tree (in-memory, per req)   │
│                                                                     │
│  2. Data Cache           — persists fetch() results across          │
│                           requests (disk/memory, Next.js managed)   │
│                                                                     │
│  3. Full Route Cache     — caches rendered HTML+RSC payload of      │
│                           static routes at build time               │
│                                                                     │
│  4. Router Cache         — client-side cache of RSC payloads,       │
│                           lives in the browser tab's memory         │
└─────────────────────────────────────────────────────────────────────┘
```

For production caching strategy, focus on layers 2 and 3:

```ts
// Server Component data fetching — cache options
await fetch('https://api.example.com/prices', {
  next: { revalidate: 60 }     // ISR: revalidate this fetch every 60 seconds
})

await fetch('https://api.example.com/user', {
  cache: 'no-store'             // never cache — always fresh (per-user dynamic data)
})

await fetch('https://api.example.com/config', {
  cache: 'force-cache'          // cache forever until manually revalidated
})
```

For segment-level control (overrides individual fetch options):

```ts
// app/products/page.tsx
export const revalidate = 3600          // revalidate the whole segment every hour
export const dynamic = 'force-dynamic'  // opts out entirely — always server-renders fresh
```

### `Cache-Control` for route handlers

Route handlers do not inherit the Data Cache. Set `Cache-Control` explicitly:

```ts
// app/api/feed/route.ts
import { NextResponse } from 'next/server'

export async function GET() {
  const data = await getFeedData()
  return NextResponse.json(data, {
    headers: {
      'Cache-Control': 's-maxage=60, stale-while-revalidate=300',
    },
  })
}
```

`s-maxage` is respected by CDNs (Vercel Edge Network, CloudFront, Fastly). `stale-while-revalidate` tells the CDN to serve a stale response while fetching a fresh one in the background — zero perceived latency on cache misses.

---

## Standalone output — the container-ready build

By default `next build` emits a full `node_modules` tree. For Docker you want `output: 'standalone'`:

```js
// next.config.js
module.exports = {
  output: 'standalone',
}
```

This traces the dependency graph and copies only the files used at runtime into `.next/standalone/`. The result is a self-contained directory that can be dropped into a Docker image without reinstalling `node_modules`.

### Dockerfile for a standalone Next.js app

```dockerfile
# syntax=docker/dockerfile:1
FROM node:20-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci

FROM node:20-alpine AS builder
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .
RUN npm run build

FROM node:20-alpine AS runner
WORKDIR /app
ENV NODE_ENV=production
# standalone build copies only required runtime files
COPY --from=builder /app/.next/standalone ./
COPY --from=builder /app/.next/static ./.next/static
COPY --from=builder /app/public ./public

EXPOSE 3000
CMD ["node", "server.js"]
```

The final image is typically 100–150 MB (node:20-alpine + standalone bundle), compared to 500+ MB for a naive `COPY . .` of `node_modules`. The two directories you always need to copy explicitly — because `standalone` does not include them — are `.next/static` and `public`.

### Deploying to kind

For BRIDGE challenges in this course the standalone Dockerfile gives you a buildable, kind-loadable image:

```bash
docker build -t myapp:prod .
kind load docker-image myapp:prod --name dojo
kubectl apply -f deploy/app.yaml
kubectl rollout status deployment/myapp -n dojo-nextjs
```

### Deploying to Vercel

Vercel detects Next.js automatically — push to the connected repo, zero configuration needed. The one operational rule: anything in `.env.local` (never committed) must be added to Vercel's project settings for the production build to see it.

```bash
vercel env add NEXTAUTH_SECRET production
vercel env add DATABASE_URL production
vercel pull --environment=preview   # sync preview env vars to local .env.local
```

---

## Observability

### OpenTelemetry via `instrumentation.ts`

Next.js 14+ supports an `instrumentation.ts` at the project root. It runs once at server startup — use it to initialize your tracing provider:

```ts
// instrumentation.ts
export async function register() {
  if (process.env.NEXT_RUNTIME === 'nodejs') {
    const { NodeSDK } = await import('@opentelemetry/sdk-node')
    const { OTLPTraceExporter } = await import('@opentelemetry/exporter-trace-otlp-http')
    const { getNodeAutoInstrumentations } = await import('@opentelemetry/auto-instrumentations-node')

    const sdk = new NodeSDK({
      traceExporter: new OTLPTraceExporter({
        url: process.env.OTEL_EXPORTER_OTLP_ENDPOINT,
      }),
      instrumentations: [getNodeAutoInstrumentations()],
    })
    sdk.start()
  }
}
```

The `NEXT_RUNTIME === 'nodejs'` guard prevents this from running in the edge runtime where the OTel Node SDK can't load. This instruments `fetch`, HTTP calls, and database queries automatically. With a Grafana Cloud or Honeycomb endpoint you get distributed traces across Server Components, route handlers, and external services.

### Structured logging

`console.log` works in development. In production you want structured JSON that log aggregators can ingest without parsing:

```ts
// lib/logger.ts
import 'server-only'

type Level = 'info' | 'warn' | 'error'

export function log(level: Level, event: string, data?: Record<string, unknown>) {
  process.stdout.write(
    JSON.stringify({ ts: new Date().toISOString(), level, event, ...data }) + '\n'
  )
}
```

In Server Components and actions: `log('info', 'user.login', { userId })` instead of `console.log('user logged in', userId)`. Each line is a JSON object on stdout — directly ingestible by Loki, Datadog, or any structured aggregator.

---

## Debugging Performance & Deployment

### Symptom → Cause → Fix

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Client JS bundle > 500 KB gzipped | Unshaken library import or a large dependency shared across all routes | Run `ANALYZE=true npm run build`; find the largest node in the client treemap; use dynamic import or a lighter library. |
| Lighthouse CLS score > 0.1 on a page with images | `<img>` without explicit dimensions, or `next/image` without a `sizes` prop | Add `width`/`height` to every `<img>`, or convert to `next/image`; add `sizes` to any `fill` or responsive image. |
| Slow TTFB on a page that should be static | A `fetch()` call somewhere in the render tree has `cache: 'no-store'`, or the segment has `dynamic = 'force-dynamic'` | Audit `fetch()` cache options; remove `no-store` from data that can be cached; check the `next build` output for static/dynamic classification. |
| Docker image is 800 MB+ | `output: 'standalone'` is missing, or `node_modules` is copied into the runner stage | Add `output: 'standalone'` to `next.config.js`; use the multi-stage Dockerfile above; never `COPY . .` in the runner stage. |
| `next build` fails with "Module not found" in standalone output | A dynamic `require()` or `fs.readFileSync` with a runtime-computed path that the dependency tracer can't follow | Copy the file explicitly in the Dockerfile; or add the package to `serverExternalPackages` in `next.config.js`. |
| `next/image` returns 400 for an external image URL | The image's hostname is not in `remotePatterns` | Add the hostname/pattern to `images.remotePatterns` in `next.config.js`. |
| Fonts cause layout shift even with `next/font` | Using `display: 'block'`, or a raw `<link>` Google Fonts tag is still present alongside `next/font` | Set `display: 'swap'`; remove any `<link>` Google Fonts tag from `<head>`. |
| Env var is `undefined` in the Vercel production build | Variable is in `.env.local` (gitignored) but was never added to Vercel's project environment variables | Add each required variable via `vercel env add <name> production`. |

### Diagnosing slow TTFB

A slow TTFB means the server took a long time to send the first byte. Three most common causes:

```
1. Cold start (edge/serverless function spinning up)
   → Instrument with OpenTelemetry; check function init time in Vercel's
     function logs ("Duration: Xms | Init Duration: Yms")
   → If init is high: reduce imports, use 'nodejs' runtime for large functions
   → Warm with a scheduled ping (cron + fetch) if cold starts are frequent

2. Sequential await chain in the render tree
   → Parallelize independent fetches:
     const [user, posts] = await Promise.all([getUser(id), getPosts(id)])
   → Move slow fetches inside Suspense boundaries so the shell flushes first

3. Missing CDN cache hit
   → Check the x-nextjs-cache response header:
     curl -I https://yourdomain.com/products | grep x-nextjs-cache
     # HIT = served from cache, MISS = rendered, STALE = background revalidation
   → If always MISS: check for no-store fetches or force-dynamic exports
   → Add stale-while-revalidate at the CDN layer to eliminate the MISS latency
```

### Checking the build's static/dynamic classification

```bash
npm run build
# the terminal output lists every route:
# ○  /about         (static)
# ●  /dashboard     (dynamic, server-rendered on every request)
# ◐  /products      (ISR, revalidates every 60s)
```

A route that you expected to be static showing as dynamic means there's a `no-store` fetch, a `cookies()` / `headers()` call, or a `searchParams` access somewhere in its render tree. Find it with a server-side log and remove it or push it inside a Suspense boundary.

> **War story.** We launched a SaaS dashboard and product immediately asked why the main page was slow on cold visits but fast on refresh. ISR was working (`revalidate: 60`), but every 60 seconds one user got a 1.2s TTFB while the cache warmed for everyone else. The fix was adding `stale-while-revalidate` at the CDN layer (`Cache-Control: s-maxage=60, stale-while-revalidate=300`) — the CDN continued serving the slightly-stale page for up to five minutes while asynchronously revalidating in the background. The "slow every minute" pattern disappeared entirely. The lesson: `revalidate` in Next.js controls how often the server *recomputes*, but without `stale-while-revalidate` at the CDN layer, the recompute is synchronous from the user's perspective. These two knobs work together; neither is complete without the other.

---

## Checkpoint

1. Your client bundle jumped from 120 KB to 310 KB after merging a PR. Walk through the exact steps to find which import caused it.
2. What does the `sizes` attribute on `next/image` control? What happens if you omit it on a `fill` image?
3. What is `output: 'standalone'` and why does it matter for Docker? Name the two directories from `.next/` that you must still copy manually into the runner stage.
4. Explain the difference between `s-maxage` and `stale-while-revalidate` in a `Cache-Control` header. When would you use both together?
5. A Server Component fetches data with `cache: 'no-store'`. What does this do to the route's build-time classification (static vs dynamic)?
6. What does the `next build` terminal output's `○` / `●` / `◐` symbols mean? What would you do if a route you expected to be static shows `●`?
7. Why does the `instrumentation.ts` OTel initialization guard with `process.env.NEXT_RUNTIME === 'nodejs'`?
8. Walk through diagnosing a slow TTFB: name the three most common causes, the tool or command that surfaces each, and the fix.

➡ Modules complete. Move to the challenges to build, ship, and verify.
