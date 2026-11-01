# Build Integrity

A colleague pushes a "quick cleanup" commit Friday evening before a long weekend. Your CI fails with a cryptic Next.js build error. The PR description says *"minor refactor, shouldn't break anything."* It did.

## Context

`setup.sh` plants a small but real Next.js 14 app under `~/.kube-dojo-work/05-build-integrity/`:

```
~/.kube-dojo-work/05-build-integrity/
├── package.json
├── next.config.js
├── app/
│   ├── layout.tsx
│   ├── page.tsx               # root page
│   ├── dashboard/
│   │   └── page.tsx           # protected page
│   └── api/
│       └── status/
│           └── route.ts       # route handler
└── components/
    └── ServerData.tsx         # the scene of the crime
```

The app has **one deliberate build-breaking mistake** somewhere in this tree. `npx next build` currently exits non-zero.

## Prerequisites

```bash
cd ~/.kube-dojo-work/05-build-integrity
npm install
```

## Mission

Make `npx next build` exit 0 with `output: 'standalone'` configured.

The verifier runs:

```bash
npx next build
```

and checks the exit code. You do not need to add features — only fix the mistake.

### What kinds of mistakes break the Next.js build?

The most common categories, in order of how often they appear on real teams:

| Category | Example |
|---|---|
| Client/server boundary violation | `'use client'` component importing `fs`, `headers()`, or `server-only` |
| Server component importing a client-only module | A Server Component `import`ing a module that uses `useState` or `useEffect` without `'use client'` |
| TypeScript type error | A prop mismatch the editor caught but the dev server hot-reloads past |
| Missing `async`/`await` on a `fetch` | Treated as a non-Promise value; fails at static analysis |
| Async Server Component without `async` keyword | `const data = await fetch(...)` in a non-async function |

Run `npx next build 2>&1 | head -60` — the first error block is almost always the real one. The subsequent noise is usually cascading import failures from the same root cause.

## Verify

```bash
bash courses/course-32-nextjs-production/challenges/05-build-integrity/verify.sh
```

Build exits 0 → flag printed.
