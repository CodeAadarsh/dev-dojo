# Multi-Stage Builds and Minimal Images

> **Module 06 · Course 37** — A Go app needs a 1 GB compiler to build but only a 5 MB binary to run. A Java app needs a 500 MB JDK to compile but just a 200 MB JRE to execute. Multi-stage builds let you use a fat environment to build and ship only the output. This module shows you how to do it right, which base images to choose, and how to verify the result.

---

## Why Multi-Stage?

Before multi-stage builds, teams had two choices:
1. Ship the build environment in the production image (huge, full of CVEs, huge attack surface)
2. Build in CI, copy artifacts manually, build a second image (fragile, two Dockerfiles to maintain)

Multi-stage builds solve this cleanly: **one Dockerfile, multiple FROM instructions**, each building on the previous. Only what you explicitly `COPY --from=` makes it into the next stage.

```
Build stage (fat):              Final stage (lean):
────────────────────            ────────────────────
golang:1.23-alpine              distroless/static
  + source code                   + compiled binary only
  + go toolchain                
  + build cache                 
  + test dependencies            
  = ~350 MB                      = ~4 MB
```

---

## Basic Multi-Stage: Go Binary on Distroless

```dockerfile
# ── Stage 1: build ──────────────────────────────────────────────
FROM golang:1.23-alpine AS build
WORKDIR /src

# Copy dependency files first (cache-friendly)
COPY go.mod go.sum ./
RUN go mod download

# Copy source and build
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build \
    -ldflags="-s -w" \
    -o /bin/app \
    ./cmd/server

# ── Stage 2: runtime ────────────────────────────────────────────
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /bin/app /app
USER nonroot:nonroot
EXPOSE 8080
ENTRYPOINT ["/app"]
```

**Flags explained:**
- `CGO_ENABLED=0`: disables C extensions → statically linked binary (no libc dependency)
- `GOOS=linux`: target OS (important when building on macOS)
- `-ldflags="-s"`: strip symbol table (smaller binary, no debug symbols)
- `-ldflags="-w"`: strip DWARF debug info (even smaller)
- `nonroot:nonroot`: UID 65532, GID 65532 — defined in the distroless image

Result: a ~5-10 MB production image that:
- Has no shell (attacker can't `exec sh`)
- Has no package manager (can't install tools)
- Runs as a non-root user
- Contains only your binary and glibc/CA certs

---

## Named Stages and --target

You can name stages and reference them by name:

```dockerfile
FROM node:20-slim AS deps
WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev

FROM node:20-slim AS test-deps
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY package*.json ./
RUN npm ci  # includes devDependencies for testing

FROM node:20-slim AS test
WORKDIR /app
COPY --from=test-deps /app/node_modules ./node_modules
COPY . .
RUN npm test  # run tests during build

FROM node:20-slim AS runtime
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY --from=test .  # only reaches here if tests passed
COPY --from=test /app/src ./src
CMD ["node", "src/server.js"]
```

```bash
# Build only up to the test stage (useful for CI)
docker build --target test -t myapp:test .

# Build the full final image
docker build -t myapp:1.0 .

# BuildKit builds stages in parallel when they don't depend on each other
# (deps and test-deps run simultaneously)
```

---

## COPY --from Variants

```dockerfile
# From a named stage in the same Dockerfile
COPY --from=build /bin/app /app

# From an external image (not a stage in this file)
COPY --from=nginx:1.27-alpine /etc/nginx/nginx.conf /etc/nginx/nginx.conf

# From a stage by index (0-based, fragile — prefer named stages)
COPY --from=0 /bin/app /app

# COPY with ownership
COPY --from=build --chown=nonroot:nonroot /bin/app /app
```

---

## Base Image Comparison

Choosing the right base image is a size, security, and compatibility tradeoff:

| Base | Typical size | Shell? | libc | Use case |
|------|-------------|--------|------|---------|
| `ubuntu:22.04` | ~70 MB | bash | glibc | Needs full Linux tools |
| `debian:bookworm-slim` | ~40 MB | bash | glibc | General purpose, trimmed |
| `alpine:3.20` | ~7 MB | sh (ash) | musl | Small, but musl != glibc |
| `gcr.io/distroless/static-debian12` | ~2 MB | **none** | **none** | Static Go/Rust binaries |
| `gcr.io/distroless/base-debian12` | ~20 MB | **none** | glibc | Dynamic binaries needing glibc |
| `gcr.io/distroless/java21-debian12` | ~190 MB | **none** | glibc + JRE | Java apps |
| `scratch` | 0 bytes | **none** | **none** | Fully static single binary |

---

## Distroless: What's In It, What's Not

Distroless images contain:
- glibc (for dynamic binaries)
- CA certificates (for HTTPS)
- tzdata (timezone data)
- A minimal `/etc/passwd` with the `nonroot` user

Distroless images do **NOT** contain:
- `/bin/sh` or any shell
- `apt`, `apk`, or any package manager
- `coreutils` (`ls`, `cat`, `grep`, etc.)
- `curl`, `wget`, `nc`, or any network tools

This means attackers who get code execution can't easily enumerate your system, download tools, or spawn a reverse shell. Debugging requires `kubectl debug` ephemeral containers — that's the tradeoff.

```bash
# Confirm there's no shell
docker run --rm gcr.io/distroless/static-debian12 /bin/sh
# docker: Error response from daemon: OCI runtime exec failed:
# exec: "/bin/sh": stat /bin/sh: no such file or directory

# Debugging distroless containers in K8s:
kubectl debug -it <pod> --image=busybox:1.36 --target=<container> -- sh
```

---

## Alpine Gotchas: musl vs glibc

Alpine uses **musl libc** instead of **glibc**. Most of the time this doesn't matter. When it does, it bites hard:

**Problem 1: Go with CGO**
```bash
# If your Go binary links against C libraries, it dynamically links glibc
CGO_ENABLED=1 go build -o app .
# This binary will NOT run on Alpine (musl != glibc)

# Fix: either static (CGO_ENABLED=0) or use a glibc base
CGO_ENABLED=0 go build -o app .  # static, works on Alpine and distroless
```

**Problem 2: Python C extensions**
```bash
# Some Python wheels are compiled against glibc
# They won't install cleanly on Alpine (need to compile from source)
# → sometimes musl-compatible wheels are missing
```

**Problem 3: DNS resolution differences**
musl's DNS resolver doesn't support `resolv.conf` search domains the same way as glibc. In Docker networking (which uses `/etc/resolv.conf` with `search` domains), Alpine containers can sometimes fail to resolve service names that work on Debian-based containers.

**Rule:** Alpine is great for simple images. For anything linking C libraries or using Python with complex C extensions, prefer `debian:slim` as your runtime base.

---

## scratch: The Zero-Byte Base

`scratch` is not an image — it's a special Docker keyword meaning "empty filesystem". Your binary is the only thing in the image.

```dockerfile
FROM golang:1.23-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o /app .

FROM scratch
COPY --from=build /app /app
# Need CA certs for HTTPS? Copy them too:
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
ENTRYPOINT ["/app"]
```

The final image size = size of your binary + CA certs ≈ 5-15 MB.

**Limitation:** No shell, no `/etc/passwd`, no nothing. If your app calls `os/user.Current()`, it'll fail (no `/etc/passwd`). Distroless solves this by providing a minimal `/etc/passwd`.

---

## dive: Visualizing Layers Interactively

`dive` is an open-source tool for exploring Docker images layer by layer:

```bash
# Install
brew install dive  # macOS

# Analyze an image
dive myapp:1.0

# Non-interactive CI mode
dive myapp:1.0 --ci  # exits non-zero if wasted space > threshold
```

dive shows:
- Left pane: layer list with sizes and the instruction that created each
- Right pane: file tree diff for the selected layer (green = added, yellow = modified, red = removed)
- Bottom: efficiency score (what percentage of the image is "wasted" by overwritten/deleted files)

```bash
# Check without installing dive:
docker history --no-trunc myapp:1.0
docker image inspect myapp:1.0 --format '{{json .RootFS.Layers}}'
```

---

## BuildKit Inline Cache for CI

When building in CI, you want to reuse the previous build's layers without spinning up a separate cache service. BuildKit's inline cache bakes layer metadata into the image itself:

```bash
# Build and push with inline cache
docker buildx build \
  --cache-from=type=registry,ref=ghcr.io/myorg/myapp:buildcache \
  --cache-to=type=registry,ref=ghcr.io/myorg/myapp:buildcache,mode=max \
  --push \
  -t ghcr.io/myorg/myapp:1.0 \
  .

# mode=max: cache all stages (not just final)
# mode=min: cache only final stage layers
```

For GitHub Actions with the official cache:
```yaml
- uses: docker/build-push-action@v5
  with:
    cache-from: type=gha
    cache-to: type=gha,mode=max
```

---

## Size Comparison Example: Real Node.js App

```bash
# Build the same app three ways
docker build -f Dockerfile.simple -t node-simple .   # single stage, full node
docker build -f Dockerfile.slim -t node-slim .       # node:20-slim, pruned deps
docker build -f Dockerfile.distroless -t node-dl .   # multi-stage, distroless

docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}" | grep node-
# node-simple      latest    1.08GB
# node-slim        latest    218MB
# node-distroless  latest    112MB
```

The 5× size reduction between single-stage and multi-stage/minimal comes from not shipping the build toolchain and dev dependencies.

---

## Checkpoint

1. What does `COPY --from=build` do, and what happens if you don't use `--from`?
2. What do the Go build flags `-s` and `-w` do to the binary?
3. When would you choose `scratch` over `distroless/static`?
4. What musl vs glibc problem can break Alpine-based containers with Go binaries using CGO?
5. What is `--target` used for in `docker build`, and when is it useful in CI?
6. What does `gcr.io/distroless/static-debian12:nonroot` contain and explicitly NOT contain?
7. How do you debug an app running in a distroless container when it crashes?
8. What is a BuildKit cache mount (`--mount=type=cache`) and how does it differ from a layer?
9. What is `mode=max` in a BuildKit registry cache-to directive?
10. If a Python C extension fails to install on Alpine but works on Debian, what is the most likely cause?

➡ Next up: **Docker Networking** — how packets actually travel from your container to the internet and back, through Linux bridges, veth pairs, iptables rules, and Docker's embedded DNS.
