# Dockerize and Deploy

Your Next.js app works locally. Now ship it: package it as a Docker image using Next.js `standalone` output, load it into your kind cluster, and prove it's running with a readiness probe.

This is the full production loop — the thing that breaks in staging at midnight.

## Prerequisites

- Docker running
- kind cluster named `dojo` (`kubectl config current-context` → `kind-dojo`)
- `kubectl` pointing at `kind-dojo`

## Context

`setup.sh` plants a working Next.js 14 app (with `output: 'standalone'` already configured) and a Dockerfile skeleton under `~/.kube-dojo-work/06-dockerize-and-deploy/`:

```
~/.kube-dojo-work/06-dockerize-and-deploy/
├── package.json
├── next.config.js
├── Dockerfile          # skeleton — fill in the multi-stage build
├── app/
│   ├── layout.tsx
│   ├── page.tsx
│   └── api/
│       └── health/
│           └── route.ts   # returns { status: "ok" }
└── components/
    └── Hero.tsx
```

## Mission

1. **Complete the Dockerfile** for a Next.js standalone image (multi-stage: builder → runner). The runner stage must use `node:20-alpine` and run the standalone server at port 3000.

2. **Build the image** and tag it `dojo-nextjs:v1`.

3. **Load it into kind**: `kind load docker-image dojo-nextjs:v1 --name dojo`

4. **Deploy** to namespace `dojo-nextjs` with:
   - A `Deployment` named `nextjs` with `replicas: 1`, image `dojo-nextjs:v1`, `imagePullPolicy: IfNotPresent`
   - A readiness probe: `httpGet` on path `/api/health`, port `3000`, `initialDelaySeconds: 5`, `periodSeconds: 5`
   - A `Service` named `nextjs` (ClusterIP, port 80 → targetPort 3000) — optional but good practice

## What `verify.sh` checks

```
✓ namespace dojo-nextjs exists
✓ Deployment nextjs has readyReplicas >= 1
✓ Pod is using image dojo-nextjs:v1
```

The verifier uses only `kubectl` and `-o jsonpath` — no jq required.

## Why standalone output matters

`next build` with `output: 'standalone'` produces `.next/standalone/` — a self-contained Node.js server with only the node_modules it actually uses. The resulting Docker image is typically **4–6× smaller** than copying the entire project into a container because:

- Dev dependencies are not included
- Only the modules imported by your pages are kept
- The `node_modules/.cache` and build intermediates are not present

A non-standalone image typically ships 500 MB+. A standalone image is commonly 120–180 MB for a real production app. At 100 deploys/day that's a meaningful CI cache and registry egress saving.

## Verify

```bash
bash courses/course-32-nextjs-production/challenges/06-dockerize-and-deploy/verify.sh
```
