# Dockerize Multi-Stage: Build Slim, Run Non-Root

A CI alert fires on a teammate's PR. The build pipeline now takes 12 minutes and
the image landing in the registry is **1.1 GB**. The Dockerfile is a single
stage — the full Go SDK is shipped into the runtime image. The security scan
before the gate: *312 CVEs, 28 high/critical, all from SDK layers with no
business being in production.* The SRE lead's review comment:
*"Multi-stage it or it doesn't ship."*

## Context

`setup.sh` plants a small Go HTTP server in your work directory:

```
~/.kube-dojo-work/04-dockerize-multistage/
├── main.go      # tiny HTTP server: GET /healthz → "ok", GET / → status line
├── go.mod       # module dojo-app, go 1.22
├── Dockerfile   # stub — write this
└── build.sh     # stub — write this
```

## Prerequisites

Docker installed and running:

```bash
docker version
```

## Mission

Write a **multi-stage `Dockerfile`** and a **`build.sh`** build script in
`~/.kube-dojo-work/04-dockerize-multistage/`. The verifier checks four
conditions in order:

| Check | Assertion |
|-------|-----------|
| Multi-stage | `Dockerfile` has **≥ 2 `FROM`** instructions |
| Build succeeds | `docker build` exits 0 |
| Non-root runtime | `docker inspect --format '{{.Config.User}}'` returns a non-empty, non-`root` / non-`0` value |
| Server responds | `GET /healthz` on the running container responds with a body containing `ok` |

**Dockerfile contract:**

- Stage 1 (builder): compile the Go binary using `golang:1.22-alpine` (or later).
  Enable `CGO_ENABLED=0` for a statically linked binary.
- Stage 2 (runtime): use `alpine:3.19` (or distroless). Create and switch to a
  non-root user. Copy only the compiled binary from the builder stage.
- App listens on port **8080**.

**`build.sh` contract:** accepts an optional `$1` image tag (default
`dojo-multistage:latest`) and runs `docker build -t "$IMAGE" .` against the
work directory.

## Why multi-stage matters

A single-stage Go image ships the entire toolchain — compiler, linker, C
headers, all stdlib sources — into prod. The attack surface is enormous and
immovable without re-imaging. Multi-stage produces a statically linked binary on
Alpine: **~900 MB → ~10 MB, ~300 CVEs → ~0**.

Non-root is the other half. A container escape as `uid=0` is immediate host
root. A container escape as `uid=1001` is a dead end — no `sudo`, no `suid`
binaries inside a distroless layer, no path forward without a separate privilege
escalation chain. Defense in depth means both: small surface and least privilege.

## Verify

```bash
bash courses/course-25-cicd/challenges/04-dockerize-multistage/verify.sh
```
