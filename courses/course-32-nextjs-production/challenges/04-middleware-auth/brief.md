# Middleware Auth Guard

During a security review the team finds that every `/dashboard/*` and `/settings` route is publicly accessible — the auth token check happens inside the page component, which means the server renders a flash of protected content before the redirect fires client-side. The fix belongs in middleware, before the request ever reaches a route.

## Context

`setup.sh` plants a starter project under `~/.kube-dojo-work/04-middleware-auth/`:

```
~/.kube-dojo-work/04-middleware-auth/
├── package.json
├── src/
│   └── middleware.ts     # stub — implement this
└── tests/
    └── middleware.test.ts  # visible sample tests (a subset of the verifier harness)
```

The test file imports `middleware` from `../src/middleware` and feeds it `NextRequest`-like objects constructed with the Node.js built-in test runner (`node --test`).

## Prerequisites

```bash
cd ~/.kube-dojo-work/04-middleware-auth
npm install
```

## Mission

Implement `src/middleware.ts` so that:

| Request | Expected behaviour |
|---|---|
| `GET /dashboard/overview` — no `session` cookie | **Redirect to `/login`** (307) |
| `GET /settings` — no `session` cookie | **Redirect to `/login`** (307) |
| `GET /dashboard/overview` — `session=abc123` cookie present | **Pass through** (no redirect) |
| `GET /login` | **Pass through** — always public |
| `GET /` | **Pass through** — public |
| `GET /_next/static/chunk.js` | **Pass through** — static asset |
| `GET /api/public` | **Pass through** — API routes are not guarded |

The verifier imports your middleware function and asserts these cases plus a few edge-path variants.

### Routing contract

Protected prefixes: `/dashboard`, `/settings`, `/account`, `/admin`.
Public exceptions that must never redirect:
- Any path starting with `/_next/`
- Any path starting with `/api/`
- Exact paths: `/login`, `/signup`, `/`, `/favicon.ico`

### Why middleware is the right place

Middleware runs on the Edge before any React render. The redirect happens before HTML is streamed, so there is no flash of protected content, no client-side navigation jank, and — crucially — no auth token round-trip on the server just to 307 back to login. Doing this in `layout.tsx` or a page component is always wrong for protected routes.

## Verify

```bash
bash courses/course-32-nextjs-production/challenges/04-middleware-auth/verify.sh
```

All tests green → flag printed.
