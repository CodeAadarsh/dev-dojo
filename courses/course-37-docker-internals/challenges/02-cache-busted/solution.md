# Solution: Cache Busted

## Step 1 — Read the broken Dockerfile

```bash
kubectl get configmap broken-dockerfile -n dojo-docker-cache -o jsonpath='{.data.Dockerfile}'
```

Output:
```dockerfile
FROM node:20-slim
WORKDIR /app
COPY . .              # <-- THE BUG: copies all source before installing
RUN npm ci --omit=dev # <-- rebuilds every time any source file changes
EXPOSE 3000
CMD ["node", "server.js"]
```

## Step 2 — Understand the cache invalidation

`COPY . .` copies every file in the build context, including `server.js`, `README.md`, and anything else. Its cache key is computed from the **contents of all those files**. Change one byte in one file → the `COPY . .` layer is a cache miss → `RUN npm ci` below it rebuilds from scratch.

The fix: copy *only* the files that `npm ci` actually needs, and copy them before anything volatile.

## Step 3 — Create the fixed ConfigMap

```bash
kubectl create configmap fixed-dockerfile \
  --from-literal=Dockerfile='FROM node:20-slim
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev
COPY . .
EXPOSE 3000
CMD ["node", "server.js"]' \
  -n dojo-docker-cache
```

## Step 4 — Verify

```bash
bash courses/course-37-docker-internals/challenges/02-cache-busted/verify.sh
```

**Flag:** `KUBE{cache_busted_by_volatile_copy}`

## Why The Fix Works

```
Before fix:          After fix:
─────────────       ─────────────────────────────
COPY . .      ← changes every commit
RUN npm ci    ← always rebuilds               COPY package.json ./  ← stable
COPY . .      ← volatile source last
              RUN npm ci  ← cached for code-only edits
```

`package.json` and `package-lock.json` only change when you add/remove/update dependencies — maybe once a week. So `RUN npm ci` now gets a cache hit on 95% of builds. That 8-minute pipeline becomes 45 seconds.

**The rule:** order Dockerfile instructions from least-frequently-changing to most-frequently-changing. Base image → OS packages → language packages → app code.
