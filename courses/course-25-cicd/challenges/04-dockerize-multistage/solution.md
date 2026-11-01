# Solution: Dockerize Multi-Stage

## Dockerfile

```dockerfile
# Stage 1 — builder: full Go SDK, compiles a statically linked binary.
# Nothing from this stage reaches the final image except the binary.
FROM golang:1.22-alpine AS builder
WORKDIR /src
COPY go.mod go.mod
COPY main.go main.go
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /out/server .

# Stage 2 — runtime: minimal Alpine, no build tools, non-root user.
FROM alpine:3.19
RUN addgroup -S app && adduser -S app -G app
USER app
COPY --from=builder /out/server /app/server
EXPOSE 8080
ENTRYPOINT ["/app/server"]
```

### Why each line matters

**`CGO_ENABLED=0`** disables C bindings and produces a fully static binary —
no glibc, no dynamic linker. The binary runs on Alpine's musl libc without
issue and would even run on `scratch` (a zero-byte base image). Without this,
`go build` can emit a dynamically linked binary that crashes on Alpine with
`no such file or directory` for the dynamic linker.

**`-ldflags="-s -w"`** strips the debug symbol table (`-s`) and the DWARF
data (`-w`), reducing binary size by ~30% with no runtime cost.

**`COPY --from=builder /out/server /app/server`** pulls exactly one file from
the builder stage. The rest of the Go SDK, the source tree, the build cache —
none of it enters the final image.

**`addgroup -S app && adduser -S app -G app`** creates a system group and user
without a home directory or password. `-S` = system account (no login shell,
no `/home`). This runs once at image build time; the image ships with the user
already created.

**`USER app`** sets the process UID for all subsequent layers and for the
running container. `docker inspect --format '{{.Config.User}}'` will show
`app`. Without this, the container defaults to `uid=0` (root).

## build.sh

```bash
#!/usr/bin/env bash
set -euo pipefail
IMAGE="${1:-dojo-multistage:latest}"
docker build -t "$IMAGE" .
echo "Built $IMAGE"
```

Accepting `$1` as the image name means the same script works for local builds
(`bash build.sh dojo-multistage:dev`) and in CI (`bash build.sh
registry.example.com/dojo-multistage:$GIT_SHA`).

## Size comparison

```bash
docker images dojo-multistage:dojo-verify --format '{{.Size}}'
# Typical output: ~10–12 MB (vs ~900 MB for a single-stage golang:1.22 image)
```

## Attacker's view

A non-root user is not a hard boundary — it is a speed bump. An attacker who
escapes the container (via a kernel CVE or a writable host path mount) lands
with `uid=1001`, not `uid=0`. On most well-configured hosts this means no
write access to system directories, no `sudo`, no `suid` tools. Combined with a
read-only root filesystem (`docker run --read-only`) and a dropped capability
set (`--cap-drop ALL`), the post-escape blast radius shrinks to near zero.

## Hardening preview

The next step after multi-stage is supply-chain hardening:

```bash
# Scan for CVEs before pushing (fails the pipeline if critical found)
trivy image --exit-code 1 --severity CRITICAL dojo-multistage:latest

# Sign the image digest (requires cosign installed + OIDC token in CI)
cosign sign --yes registry.example.com/dojo-multistage@$(docker inspect --format '{{.Id}}' dojo-multistage:latest)
```

Pin base images to digests in production to prevent tag mutation attacks:

```dockerfile
FROM alpine:3.19@sha256:13b7e62e8df80264dbb747995705a986aa530415763a6c58f84a3ca8af9a5bcd
```
