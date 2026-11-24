# Dockerfile Mastery — Beyond the Basics

> **Module 05 · Course 37** — You already know cache ordering and multi-stage builds from the K8s course. This module goes deeper on the instructions that trip up experienced developers: ARG vs ENV, shell form vs exec form (and why it breaks `docker stop`), BuildKit secrets, cache mounts, and `.dockerignore`. Each section explains the WHY before the HOW.

---

## ARG vs ENV — Build Time vs Runtime

These look similar but are fundamentally different:

| Feature | `ARG` | `ENV` |
|---------|-------|-------|
| Available during build | Yes | Yes |
| Available in running container | **No** | **Yes** |
| Visible in `docker inspect` | No | Yes |
| Can be set with `--build-arg` | Yes | No (use ARG, then set ENV from ARG) |
| Creates a layer | No | Yes |

```dockerfile
# ARG: exists only during the build
ARG NODE_VERSION=20

FROM node:${NODE_VERSION}-slim   # ARG value used here

# After FROM, declare it again if you want to use it in later steps
ARG NODE_VERSION

RUN echo "Building with Node ${NODE_VERSION}"
# NODE_VERSION is gone after this build step — not in the final image

# ENV: persists in the final image (visible in docker inspect)
ENV APP_ENV=production
ENV PORT=3000

# In the container:
#   echo $APP_ENV → "production"
#   echo $PORT    → "3000"
#   echo $NODE_VERSION → "" (gone)
```

**The secret leak trap:** Never put secrets in `ENV`. They end up in `docker inspect` output, in Docker event logs, and in the image history. Use `ARG` for build secrets, or better — use BuildKit secrets (covered below).

```bash
# BAD: visible to anyone who can inspect the image
ENV NPM_TOKEN=npm_abc123...

# Also bad: ARG values appear in docker history
ARG NPM_TOKEN
RUN npm config set //registry.npmjs.org/:_authToken=${NPM_TOKEN}
# docker history shows the full ARG value!
```

---

## ARG Before FROM — The Multi-Platform Trick

Here's a subtle ARG behaviour: you can declare ARG before FROM to parameterize the base image itself.

```dockerfile
# This ARG is available BEFORE FROM
ARG TARGETPLATFORM=linux/amd64
ARG BASE_IMAGE=node:20-slim

FROM ${BASE_IMAGE}

# To use ARG values after FROM, re-declare them (they reset after FROM)
ARG TARGETPLATFORM
RUN echo "Building for $TARGETPLATFORM"
```

BuildKit automatically sets `TARGETPLATFORM`, `TARGETOS`, `TARGETARCH` when using `--platform`:

```dockerfile
ARG TARGETOS
ARG TARGETARCH

FROM golang:1.23-alpine AS build
ARG TARGETOS
ARG TARGETARCH
RUN GOOS=${TARGETOS} GOARCH=${TARGETARCH} go build -o /bin/app .
```

```bash
docker buildx build --platform linux/amd64,linux/arm64 -t myapp:1.0 --push .
# BuildKit builds both platforms, with TARGETOS/TARGETARCH set correctly for each
```

---

## Shell Form vs Exec Form — The Signal Problem

Every instruction that runs commands (`RUN`, `CMD`, `ENTRYPOINT`) has two forms:

```dockerfile
# Shell form — passes to /bin/sh -c
CMD node server.js
RUN apt-get install -y curl

# Exec form — calls execve() directly, no shell
CMD ["node", "server.js"]
RUN ["apt-get", "install", "-y", "curl"]
```

**Why this matters for `docker stop`:**

```
Shell form:                           Exec form:
─────────────────────────             ─────────────────────────
/bin/sh (PID 1)                       node (PID 1)
  └── node (PID 2)                    
                                      
docker stop → SIGTERM to PID 1        docker stop → SIGTERM to PID 1
  → /bin/sh receives SIGTERM            → node receives SIGTERM
  → sh ignores it (default)             → node handles gracefully
  → 10 second timeout                   → clean shutdown
  → SIGKILL                             
```

`sh` doesn't forward signals to its children by default. So with shell form, your Node.js / Python / Go app never sees `SIGTERM`. It just gets `SIGKILL` after 10 seconds — no graceful drain, no connection closure, no cleanup.

```bash
# See this in action
docker run --name signal-test nginx:1.27-alpine  # exec form — works fine
time docker stop signal-test
# Stopped in < 1 second (nginx handles SIGTERM)

# Now try with a custom shell-form CMD (simulated):
docker run --name signal-bad --entrypoint "" nginx:1.27-alpine \
  sh -c 'nginx -g "daemon off;"'
time docker stop signal-bad
# Takes 10 seconds — sh ignores SIGTERM, timeout hits, SIGKILL fires
```

**Rule:** Always use exec form for `CMD` and `ENTRYPOINT` in production images.

---

## The Full ENTRYPOINT/CMD Matrix

Understanding what actually executes:

| Dockerfile | `docker run` extra args | PID 1 command |
|------------|------------------------|---------------|
| `ENTRYPOINT ["ep"] CMD ["default"]` | (nothing) | `ep default` |
| `ENTRYPOINT ["ep"] CMD ["default"]` | `override` | `ep override` |
| `ENTRYPOINT ["ep"]` (no CMD) | (nothing) | `ep` |
| `ENTRYPOINT ["ep"]` | `a b` | `ep a b` |
| `CMD ["cmd"]` (no ENTRYPOINT) | (nothing) | `cmd` (exec form) |
| `CMD cmd` (shell form, no ENTRYPOINT) | (nothing) | `/bin/sh -c "cmd"` |
| (neither) | `a b` | `a b` |

The override with `--entrypoint`:
```bash
docker run --entrypoint /bin/sh myimage -c "ls /"
# --entrypoint overrides ENTRYPOINT, additional args replace CMD
```

---

## HEALTHCHECK

Docker can track container health independently of whether the process is running:

```dockerfile
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -qO- http://localhost:8080/health || exit 1
```

| State | Meaning |
|-------|---------|
| `starting` | Within `--start-period`, results ignored |
| `healthy` | Last check succeeded |
| `unhealthy` | `--retries` consecutive failures |

```bash
docker inspect <container> --format '{{.State.Health.Status}}'
docker inspect <container> --format '{{json .State.Health}}' | python3 -m json.tool
```

**In Kubernetes:** Docker's `HEALTHCHECK` is **ignored**. K8s uses its own `livenessProbe`, `readinessProbe`, `startupProbe`. Use `HEALTHCHECK NONE` in your Dockerfile when targeting K8s — it documents that health checking is the orchestrator's job.

```dockerfile
# In K8s-targeted images
HEALTHCHECK NONE
```

---

## ONBUILD — Triggered in Child Images

`ONBUILD` registers an instruction that runs only when this image is used as a base in another Dockerfile.

```dockerfile
# Base image Dockerfile
FROM node:20-slim
WORKDIR /app
ONBUILD COPY package*.json ./
ONBUILD RUN npm ci --omit=dev
ONBUILD COPY . .
CMD ["node", "server.js"]
```

```dockerfile
# App Dockerfile — inheriting the base
FROM my-company/node-base:1.0
# The ONBUILD instructions fire here automatically!
# COPY package*.json ./ runs
# RUN npm ci runs
# COPY . . runs
# Then:
# No other instructions needed — inherited CMD runs the app
```

ONBUILD is useful for standardized base images across a team. The gotcha: it's invisible when you look at the app's Dockerfile — you need to read the base image's history.

```bash
docker history my-company/node-base:1.0 | grep ONBUILD
```

---

## BuildKit Cache Mounts — The npm ci That Never Re-Downloads

BuildKit (the modern build engine, enabled by default in Docker 23+) adds `--mount` to `RUN` instructions. The most useful: `type=cache`.

```dockerfile
# Without cache mount: npm ci re-downloads from the internet on every build
RUN npm ci

# With cache mount: ~/.npm is preserved between builds (not in the image)
RUN --mount=type=cache,target=/root/.npm \
    npm ci --cache /root/.npm
```

The cache directory is **persisted on the builder host** between builds but **never ends up in the image**. First build still downloads, but subsequent builds reuse the cache even after the package.json changes (BuildKit invalidates the layer but keeps the cache).

```dockerfile
# Python example
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install -r requirements.txt

# Go modules
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download
```

```bash
# BuildKit must be enabled (default in Docker 23+, or set env var)
DOCKER_BUILDKIT=1 docker build -t myapp .

# Check cache usage
docker buildx du  # shows BuildKit cache disk usage
```

---

## BuildKit Secrets — Credentials That Never Land in a Layer

The old problem: needing an NPM token or SSH key during build, without baking it into a layer.

```dockerfile
# WRONG: token appears in docker history
ARG NPM_TOKEN
RUN echo "//registry.npmjs.org/:_authToken=${NPM_TOKEN}" > .npmrc && \
    npm ci && \
    rm .npmrc
# Token still in layer 2 even after rm!

# RIGHT: BuildKit secret — present during the RUN, never committed to any layer
RUN --mount=type=secret,id=npmrc,target=/root/.npmrc \
    npm ci
```

```bash
# Build with the secret (read from a file)
echo "//registry.npmjs.org/:_authToken=npm_abc123" > .npmrc
docker buildx build \
  --secret id=npmrc,src=.npmrc \
  -t myapp .

# Or from an environment variable
docker buildx build \
  --secret id=npmrc,env=NPM_TOKEN \
  -t myapp .
```

The secret is mounted at `/run/secrets/<id>` (or your custom `target=`) only for the duration of that `RUN` instruction. No layer is created. `docker history --no-trunc` shows no trace of it.

For SSH keys (private Git repos):

```dockerfile
RUN --mount=type=ssh \
    git clone git@github.com:myorg/private-repo.git
```

```bash
docker buildx build --ssh default=$SSH_AUTH_SOCK -t myapp .
```

---

## Heredoc Syntax in Dockerfiles

Since Docker 1.4 (Dockerfile syntax 1.4+), you can write multi-line `RUN` instructions without ugly `&&` chains:

```dockerfile
# syntax=docker/dockerfile:1.4
FROM ubuntu:22.04

RUN <<EOF
apt-get update
apt-get install -y curl wget git
rm -rf /var/lib/apt/lists/*
EOF

# Or with an explicit shell
RUN <<'PYEOF' python3
import os
import json
config = {"env": os.environ.get("APP_ENV", "production")}
with open("/app/config.json", "w") as f:
    json.dump(config, f)
PYEOF

# COPY with heredoc — create files inline
COPY <<EOF /app/config.json
{"env": "production", "port": 3000}
EOF
```

The `# syntax=docker/dockerfile:1.4` line at the top is a **BuildKit frontend directive** — it pins the Dockerfile syntax version, which is itself pulled as a Docker image. This is why new Dockerfile features don't require a newer Docker daemon — just a newer syntax image.

---

## .dockerignore — The Build Context Problem

When you run `docker build .`, Docker tars the entire current directory (the **build context**) and sends it to the daemon **before** the first instruction runs. If you have `node_modules/` (200 MB), `.git/` (50 MB), or test artifacts, every build pays the tarring cost even if no `COPY` touches them.

```bash
# See how big your context is
docker build --no-cache --progress=plain . 2>&1 | head -5
# [+] Building 0.5s (3/3)
#  => [internal] load build definition from Dockerfile    0.0s
#  => [internal] load .dockerignore                       0.0s
#  => [internal] load build context                       0.4s   ← 0.4s to upload 150MB!
#  => => transferring context: 150MB
```

Create `.dockerignore` in your project root:

```gitignore
# .dockerignore
node_modules/
.git/
*.log
.env*
!.env.example
dist/
coverage/
.DS_Store
*.test.js
__pycache__/
*.pyc
.pytest_cache/
```

After adding this, context size drops to just your source files. Build times improve significantly on large projects.

**Important:** `.dockerignore` uses the same pattern syntax as `.gitignore`. `!` prefix negates an exclusion.

---

## Checkpoint

1. What is the key difference between `ARG` and `ENV`? Can you use `ARG` to pass runtime configuration?
2. Why does shell form `CMD node server.js` break graceful shutdown, and what's the fix?
3. What does `docker stop` send to PID 1, and what happens if PID 1 is `/bin/sh`?
4. If `ENTRYPOINT ["ep"]` and `CMD ["a"]` are set, and you run `docker run image b`, what executes?
5. What does a BuildKit cache mount (`--mount=type=cache`) persist between builds and what doesn't it persist?
6. Why is `--mount=type=secret` safer than `ARG NPM_TOKEN` even if you delete `.npmrc` in the same RUN?
7. What is the build context, and why does `.dockerignore` improve build speed?
8. What does `HEALTHCHECK NONE` communicate in a K8s-targeted Dockerfile?
9. When does an `ONBUILD` instruction fire?
10. What does the `# syntax=docker/dockerfile:1.4` comment do, and why is it not just a comment?

➡ Next up: **Multi-Stage Builds and Minimal Images** — taking the Dockerfile skills further: how to ship a 5 MB image for a Go app that starts from a 1 GB build environment.
