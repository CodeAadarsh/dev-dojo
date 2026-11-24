# Cache Busted

It's 2 AM. The on-call pager goes off. CI is red. You look at the build logs and find something that makes your eye twitch: **every single build is re-downloading and reinstalling all 47 npm packages from scratch**, even when only a README was changed.

The pipeline has been slow for months. Nobody knew why. You're going to fix it right now.

## Mission

A ConfigMap named `broken-dockerfile` in namespace `dojo-docker-cache` contains the broken Dockerfile. Your job is to:

1. Read the broken Dockerfile from the ConfigMap.
2. Find the instruction that's destroying the build cache.
3. Fix it and store your corrected Dockerfile in a new ConfigMap named `fixed-dockerfile` in the same namespace.

The verifier will check that your fixed Dockerfile has the correct layer order — specifically that `COPY package` appears *before* `RUN npm`.

## Why This Matters

The Docker build cache works **top-down**. Each instruction is a layer. The moment one layer's inputs differ from the last cached run, every layer below it rebuilds from scratch.

```
Instruction order:    What busts the cache?
─────────────────    ──────────────────────
COPY . .          ←  ANY source file change (even a typo in README)
RUN npm ci        ←  rebuilds every time the line above changes
```

Flip the order and the expensive step becomes cheap:

```
COPY package.json package-lock.json ./   ← only changes if deps change
RUN npm ci                               ← cached for all code-only edits
COPY . .                                 ← volatile source goes last
```

The packages don't change with every commit. The source code does. Put stable things first, volatile things last.

## Setup

```bash
bash courses/course-37-docker-internals/challenges/02-cache-busted/setup.sh
```

After setup, read the broken Dockerfile:
```bash
kubectl get configmap broken-dockerfile -n dojo-docker-cache -o jsonpath='{.data.Dockerfile}'
```

## Verifying

```bash
bash courses/course-37-docker-internals/challenges/02-cache-busted/verify.sh
```
