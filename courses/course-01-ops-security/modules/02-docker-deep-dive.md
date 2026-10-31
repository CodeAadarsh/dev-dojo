# Docker Deep-Dive for Kubernetes

> **Module 02 · Course 01** — Kubernetes schedules *containers*, but it never builds them. The thing it runs is an **OCI image**, and most "mysterious" pod behaviour — slow pulls, bloated nodes, `ImagePullBackOff`, a cluster that won't run the image you just built — is really an image problem wearing a Kubernetes costume. This module makes you fluent in the layer below the Pod.

You build images already. This goes slow on the parts that bite in production: cache ordering, digests vs tags, why your locally-built image is invisible to `kind`, and the handful of securityContext fields that turn a container from "runs" into "runs safely."

---

## The image is a stack of read-only layers

A Docker/OCI image is not a tarball of a filesystem — it's an **ordered stack of layers**, each a filesystem diff, composed at runtime by a **union filesystem** (overlayfs on modern Linux).

```
┌──────────────────────────────────────────────────────────────┐
│  CONTAINER (running)                                           │
│  ┌──────────────────────────────────────────────────────────┐│
│  │  thin writable layer  (copy-on-write, dies with container)││   <- rw
│  └──────────────────────────────────────────────────────────┘│
│  ══════════════ union mount (overlayfs) ══════════════════════│
│  ┌──────────────────────────────────────────────────────────┐│
│  │  L4  COPY app.jar /app/           (your code)             ││   \
│  ├──────────────────────────────────────────────────────────┤│    |
│  │  L3  RUN pip install -r reqs.txt  (dependencies)          ││    | read-only
│  ├──────────────────────────────────────────────────────────┤│    | shared across
│  │  L2  RUN apt-get install ...      (OS packages)           ││    | containers
│  ├──────────────────────────────────────────────────────────┤│    |
│  │  L1  FROM python:3.12-slim        (base image)            ││   /
│  └──────────────────────────────────────────────────────────┘│
└──────────────────────────────────────────────────────────────┘
```

Consequences worth internalizing:

- **Layers are content-addressed and cached by digest.** Two images that share a base share those layer blobs on disk and on the wire — pulled once per node, reused everywhere.
- **Every `RUN`/`COPY`/`ADD` creates a new layer.** `ENV`, `WORKDIR`, `LABEL`, `CMD` only add metadata (no filesystem layer).
- **Layers are additive — you cannot shrink an earlier one.** `RUN rm bigfile` in a later layer hides the file but the bytes still ship in the earlier layer. Deleting in a *different* `RUN` than the one that created the data is the classic "my image is still 2 GB" bug.
- **The writable layer is per-container and ephemeral.** Anything written at runtime lives in copy-on-write scratch that dies with the container. This is *why* you need Volumes for state — and why `readOnlyRootFilesystem` (below) is cheap to adopt.

---

## Efficient Dockerfiles: order by rate of change

The build cache invalidates **top-down**: the first instruction whose inputs changed busts every layer below it. So order instructions from **least** to **most** frequently changing. Your source code changes every commit; your dependency manifest changes weekly; your base image changes monthly.

```dockerfile
# ✗ Slow — any source edit reinstalls every dependency
FROM node:20-slim
COPY . .                      # <- app code first: cache dies on every edit
RUN npm ci                    #    so this re-runs every single build
CMD ["node", "server.js"]
```

```dockerfile
# ✓ Fast — deps cached until package files actually change
FROM node:20-slim
WORKDIR /app
COPY package.json package-lock.json ./   # <- only the manifest
RUN npm ci --omit=dev                     #    cached unless manifest changes
COPY . .                                  # <- volatile source last
CMD ["node", "server.js"]
```

| Principle | Why it matters |
|-----------|----------------|
| Copy dependency manifests before source | Dependency install (the slow step) stays cached across code edits |
| Combine related `RUN`s with `&&` | Fewer layers; clean up in the **same** layer (`apt-get ... && rm -rf /var/lib/apt/lists/*`) |
| Use a `.dockerignore` | Keeps `node_modules`, `.git`, secrets out of the build context (faster, safer) |
| Pin the base tag | Reproducible builds; see tags-vs-digests below |

> **Build context gotcha:** `docker build .` tars the *entire* directory and ships it to the daemon before the first instruction runs. A stray 500 MB artifact or `.git` in the context slows every build even if no `COPY` references it. `.dockerignore` fixes this.

> **The silent cache-buster: `ADD`/`COPY` of a changing file high in the Dockerfile.** A `COPY VERSION /VERSION` or a build-arg like `ARG BUILD_ID` placed *above* your dependency install busts the cache on every build even though nothing about the dependencies changed. Keep anything that changes per-build (version stamps, git SHAs, `ARG CACHEBUST`) **below** the expensive cached layers, or inject it at runtime via env instead of baking it in.

---

## Multi-stage builds: ship the output, not the toolchain

A compiler, JDK, or `node_modules/.cache` has no business in your production image. Multi-stage builds let you build in a fat stage and copy **only the artifact** into a lean final stage.

```dockerfile
# ---- stage 1: build (fat, has the toolchain) ----
FROM golang:1.23-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o /bin/app ./cmd/server

# ---- stage 2: runtime (tiny, no compiler) ----
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /bin/app /app
USER nonroot:nonroot
ENTRYPOINT ["/app"]
```

The final image contains one static binary and a CA bundle — no shell, no package manager, no Go toolchain. A ~900 MB build stage becomes a ~10 MB shipped image. Fewer bytes means faster pulls, faster pod start, and a smaller attack surface.

---

## Minimal base images: distroless, alpine, scratch

| Base | Size | Has a shell? | Use when |
|------|------|-------------|----------|
| `ubuntu` / `debian` | ~75–120 MB | yes | You genuinely need a full userland |
| `*-slim` | ~30–75 MB | yes | General purpose, trimmed package set |
| `alpine` | ~5–10 MB | yes (`/bin/sh`, musl libc) | Small, but musl ≠ glibc — watch for DNS/so quirks |
| `gcr.io/distroless/*` | ~2–20 MB | **no** | Production: app + runtime deps, nothing else |
| `scratch` | 0 | **no** | A single static binary (Go/Rust) |

Smaller base = fewer CVEs to patch, fewer bytes to pull, fewer tools for an attacker who lands a shell. **Distroless** has no `sh`, so an RCE can't `curl | sh` or spawn a reverse shell the easy way — the trade-off is you debug with `kubectl debug` ephemeral containers instead of `exec sh`.

> **The debugging trade-off is a feature.** You lose `kubectl exec -- sh` into a distroless pod. You gain an attacker who also can't get a shell. In Course 01's world we accept that and reach for `kubectl debug -it <pod> --image=busybox --target=<container>` to attach a throwaway toolbox — the app container stays shell-free.

---

## Tags vs digests — and why prod pins digests

A **tag** (`nginx:1.27-alpine`) is a *mutable pointer*. The registry can re-point it at new bytes tomorrow. A **digest** (`nginx@sha256:...`) is the *immutable content hash* of the exact manifest — it can never mean different bytes.

```bash
# resolve a tag to the digest it currently points at
docker buildx imagetools inspect nginx:1.27-alpine | grep Digest
# -> Digest: sha256:abc123...

# pin it for production
#   image: nginx:1.27-alpine@sha256:abc123...
```

```
   tag  nginx:1.27-alpine  ──mutable──►  [ manifest today ]
                             (re-point)►  [ manifest tomorrow ]   ← silent change!

digest nginx@sha256:abc123 ──immutable──► [ exactly these bytes, forever ]
```

Why this matters in Kubernetes specifically:

- **Reproducibility.** A Deployment pinned to a tag can run *different bytes on different nodes* if the tag moved between pulls. A digest guarantees every replica is byte-identical.
- **Supply-chain safety.** A compromised or re-pushed tag is a classic attack. A digest a reviewer approved can't be swapped underneath you.
- **`imagePullPolicy` interaction.** The default policy is `IfNotPresent` for a fixed tag but `Always` for `:latest`. A digest is always exact, so the kubelet can trust a cached layer set. Pin a tag for humans to read **and** a digest for the machine to enforce.

---

## Registries and `imagePullSecrets`

An image reference is `[registry/]repository[:tag][@digest]`. No registry prefix means Docker Hub (`docker.io/library/...`). Private registries (GHCR, ECR, Harbor, an internal Artifactory) require credentials the kubelet uses at pull time.

```bash
# create a docker-registry Secret the kubelet can use
kubectl -n dojo-apps create secret docker-registry regcred \
  --docker-server=ghcr.io \
  --docker-username="$GH_USER" \
  --docker-password="$GH_PAT" \
  --dry-run=client -o yaml | kubectl apply -f -
```

```yaml
# attach it to the pod spec (or the ServiceAccount, to apply cluster-wide)
spec:
  imagePullSecrets:
    - name: regcred
  containers:
    - name: app
      image: ghcr.io/acme/app:1.4.2@sha256:...
```

> **Attach the pull secret to the ServiceAccount**, not every pod, when a whole namespace pulls from the same private registry: `kubectl -n dojo-apps patch sa default -p '{"imagePullSecrets":[{"name":"regcred"}]}'`. Every pod using that SA inherits it — one place to rotate.

---

## `kind load docker-image` — why local images aren't automatic

This is the single most common "it works on my machine, not in the cluster" trap with `kind`. Your `kind` nodes are **containers with their own container runtime and their own image store** — physically separate from your host's Docker daemon.

```
┌─ your Mac: host Docker daemon ─┐        ┌─ kind node: dojo-control-plane ─┐
│  docker build -t myapp:dev .   │        │  containerd image store         │
│  image store:                  │        │  (empty — never saw myapp:dev)  │
│    myapp:dev   ✓ here          │  ✗───► │    myapp:dev   ✗ NOT here       │
└────────────────────────────────┘ no link└─────────────────────────────────┘
```

So a Pod referencing `myapp:dev` hits `ErrImagePull` / `ImagePullBackOff` — the kubelet tries to pull `docker.io/library/myapp:dev` from the internet and fails. Two fixes:

```bash
# option A: push the local image into every kind node's store
kind load docker-image myapp:dev --name dojo

# option B: build straight for the node runtime, then load
docker build -t myapp:dev . && kind load docker-image myapp:dev --name dojo
```

Then set `imagePullPolicy: IfNotPresent` (or `Never`) so the kubelet uses the loaded copy instead of trying to pull. With `:latest` the default policy flips to `Always` and your loaded image gets ignored — another reason to never use `:latest`.

---

## From image to running container inside a Pod

The journey from `kubectl apply` to a process on a node, for one container:

```
kubectl apply ──► api-server ──► scheduler picks a node ──► kubelet on that node
                                                                │
   ┌────────────────────────────────────────────────────────────┘
   ▼
 kubelet ──CRI──► containerd ──► 1. pull manifest + layers (unless cached)
                                 2. unpack layers into an overlayfs rootfs
                                 3. create a sandbox (the "pause" container
                                    holding the Pod's network + IPC namespaces)
                                 4. runc: new namespaces + cgroups + the rootfs
                                 5. exec ENTRYPOINT/CMD as PID 1 in the container
```

- **CRI** (Container Runtime Interface) is the gRPC contract between kubelet and the runtime (containerd, CRI-O). Docker-the-daemon was removed as a runtime in v1.24 — the *image format* it produces (OCI) is unchanged, which is why your Dockerfiles still work.
- **The `pause` container** is the near-invisible container that owns the Pod's Linux namespaces. App containers *join* its network namespace — that's why every container in a Pod shares one IP and `localhost`.
- **`ENTRYPOINT` vs `CMD`:** `ENTRYPOINT` is the executable; `CMD` is the default args. A Pod's `command:` overrides `ENTRYPOINT`; `args:` overrides `CMD`. Get this wrong and you get `exec format error` or a container that exits instantly.

---

## OCI basics

"Docker image" is shorthand. The real standards are the **OCI** (Open Container Initiative) specs, which is why Podman, Buildah, containerd, and `kind` all interoperate with what you build:

| OCI spec | Defines |
|----------|---------|
| **Image spec** | The on-disk format: a manifest + config JSON + ordered layer blobs, all content-addressed by sha256 |
| **Runtime spec** | How a runtime (`runc`) turns an unpacked rootfs + config into a running process (namespaces, cgroups, mounts) |
| **Distribution spec** | The registry HTTP API for push/pull |

A **manifest list** (OCI index) maps one tag to per-architecture manifests, so `nginx:1.27-alpine` resolves to the arm64 image on your M2 Mac and amd64 on a CI node — same tag, different bytes, selected by platform. When you pin a digest, pin the one for the architecture your nodes actually run.

> **arm64 vs amd64 is the Apple-Silicon tax.** You develop on an M2 (arm64) and your prod nodes are almost certainly amd64. `docker build` defaults to *your* host arch, so an image that runs fine in your kind cluster can land on an amd64 node as `exec format error` (the kernel can't run an arm64 ELF). Build multi-arch with `docker buildx build --platform linux/amd64,linux/arm64 --push`, or at minimum `--platform linux/amd64` for images bound for a work cluster. Inspect what you actually produced with `docker buildx imagetools inspect <ref>` — it lists every platform in the manifest list.

---

## Debugging image builds & pulls

Image problems announce themselves as pod `Waiting` reasons, build-time cache misses, or runtime `exec format error`. The trick is reading the *reason string* precisely — `ErrImagePull` and `ImagePullBackOff` mean different things, and both differ from `InvalidImageName`. Start with `describe`, which puts the real reason in the events at the bottom.

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `ErrImagePull` then `ImagePullBackOff` | Pull failed (bad name/tag, no such image in registry, auth, or local image never loaded) | Read the event; fix the ref / add `imagePullSecrets` / `kind load` the image |
| `ErrImagePull`, event says `manifest unknown` / `not found` | Tag or repo doesn't exist in the registry (typo, wrong registry) | Correct the image ref; verify with `crane`/`docker manifest inspect` |
| `ErrImagePull`, event says `unauthorized` / `denied` | Private registry, missing or wrong `imagePullSecrets` | Create a `docker-registry` secret, attach to pod or SA |
| `ImagePullBackOff` for a *locally built* image | kind nodes never saw your host image | `kind load docker-image <img> --name dojo` + `imagePullPolicy: IfNotPresent` |
| Pod `Running` → instant `CrashLoopBackOff`, logs show `exec format error` | Image built for the wrong CPU arch (arm64 image on amd64 node) | Rebuild with `--platform linux/amd64` (or multi-arch buildx) and reload |
| `InvalidImageName` | Malformed ref (bad chars, double tag, uppercase repo) | Fix the `image:` string |
| Build re-runs `npm ci`/`pip install` every time | Cache busted — volatile file copied above the install step | Reorder: manifests before source; move version stamps below |
| Image is 1–2 GB when it should be tens of MB | Toolchain/build deps shipped; `rm` in a later layer than the create | Multi-stage build; clean up in the *same* `RUN` |
| `no space left on device` during build/pull | Docker VM disk full of dangling layers & build cache | `docker system df` then `docker system prune` / `builder prune` |

### Diagnose each — the exact commands

**Read the actual pull reason first.** The event line is authoritative; the short status column is not:

```bash
kubectl describe pod <name> | sed -n '/Events:/,$p'
kubectl get pod <name> -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}: {.status.containerStatuses[0].state.waiting.message}{"\n"}'
```

**`ImagePullBackOff` vs `ErrImagePull`.** `ErrImagePull` is the *first* failed attempt; `ImagePullBackOff` is the kubelet backing off and retrying with exponential delay. Same root cause — read the message, don't just read the status.

**Local image never loaded** (the kind classic). Check what the node runtime actually has — not your host:

```bash
docker build -t myapp:dev .
docker exec dojo-control-plane crictl images | grep myapp   # empty => not loaded
kind load docker-image myapp:dev --name dojo
docker exec dojo-worker crictl images | grep myapp          # confirm on a WORKER too
```

> **`kind load` gotcha — it is a point-in-time copy to the nodes that exist now.** Rebuild the image and the nodes still hold the *old* bytes under the same tag, so with `imagePullPolicy: IfNotPresent` the kubelet happily reuses the stale copy and your fix "doesn't take." Either load-then-`kubectl rollout restart`, or tag each build uniquely (`myapp:dev-$(git rev-parse --short HEAD)`). And a node added *after* the load has an empty store — reload. `:latest` makes this worse: it flips `imagePullPolicy` to `Always`, so the kubelet ignores your loaded image entirely and tries the internet.

**Wrong architecture.** Confirm what you built vs what the node needs:

```bash
docker image inspect myapp:dev --format '{{.Architecture}}'   # arm64 on an M2
docker exec dojo-control-plane uname -m                       # the node's arch
docker buildx build --platform linux/amd64 -t myapp:dev . --load
```

**Cache busting during builds.** See which step re-ran:

```bash
docker build --progress=plain -t myapp:dev .    # "CACHED" vs a re-run step is visible per-line
docker history myapp:dev                         # per-layer size + the instruction that made it
```

The first non-`CACHED` line is your cache-bust point — everything below it rebuilt. If it's your dependency install, something volatile sits above it.

**Huge images.** Find the fat layer before you blame the base:

```bash
docker history --no-trunc myapp:dev | sort -k1 -h     # biggest layers surface
dive myapp:dev                                        # (if installed) interactive layer explorer
docker system df                                      # images / build cache / volumes disk use
```

A single `RUN apt-get install ... && rm -rf /var/lib/apt/lists/*` beats two separate `RUN`s: the cleanup only shrinks the image if it's in the **same** layer that created the data.

> **War story.** A teammate's service passed every build and ran clean in the local kind dojo, then `CrashLoopBackOff`'d the instant it hit the staging cluster — `exec format error`, nothing in the app logs because the process never started. He'd built on his M-series Mac; staging ran amd64. It was invisible locally precisely *because* kind runs on the same arm64 host, so the image looked healthy. The CI fix was two parts: build with `buildx --platform linux/amd64` for anything leaving a laptop, and add a pre-deploy gate that reads `docker buildx imagetools inspect` and fails if the required platform is missing from the manifest list. "Works on my cluster" is the new "works on my machine," and arch is the sneakiest reason why.

---

## Security thread: make the container run *safely*, not just run

Everything above is also attack surface. The defaults are permissive; tighten them in the Pod spec.

```yaml
spec:
  securityContext:
    runAsNonRoot: true            # refuse to start if the image runs as root
    seccompProfile:
      type: RuntimeDefault        # block exotic syscalls
  containers:
    - name: app
      image: ghcr.io/acme/app:1.4.2@sha256:...
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true     # writable layer is read-only; mount emptyDir for /tmp
        runAsUser: 10001
        capabilities:
          drop: ["ALL"]                  # drop every Linux capability...
          add: ["NET_BIND_SERVICE"]      # ...re-add only if you truly bind <1024
```

- **Non-root `USER` in the Dockerfile** is the first line; `runAsNonRoot: true` in the Pod enforces it so a root image fails closed instead of running privileged.
- **`readOnlyRootFilesystem: true`** neutralizes the "download a tool and run it" step of most container exploits — the attacker can't write to the filesystem. Give the app a writable `emptyDir` only where it genuinely needs one (`/tmp`, a cache dir).
- **Drop ALL capabilities** then add back the one or two you need. A web server almost never needs `SYS_ADMIN`, `NET_RAW`, or `SYS_PTRACE`.
- **Scan before you ship.** `trivy image ghcr.io/acme/app:1.4.2` lists CVEs by severity and whether a fix exists — wire it into CI and fail the build on `HIGH`/`CRITICAL` with a fix available.
- **Never `:latest`.** It's unpinnable, flips `imagePullPolicy` to `Always`, breaks rollbacks (what did the last `:latest` even point at?), and makes "which bytes are in prod" unanswerable.

> **Every byte you don't ship is a byte you don't have to defend.** A distroless, non-root, read-only, capability-dropped container pinned to a digest is boring to attack — which is exactly the goal.

---

## Checkpoint

You're ready for the Pods module when you can, without looking anything up:

1. Explain why `COPY package.json` before `COPY . .` makes rebuilds faster.
2. Write a two-stage Dockerfile that ships only a compiled binary on a distroless base.
3. State one concrete reason production should pin an image **digest**, not just a tag.
4. Explain why a freshly `docker build`-ed image gives `ImagePullBackOff` in `kind` and the two-command fix.
5. Name the four securityContext fields that make a container non-root, read-only, non-escalating, and capability-dropped.
6. Say what the `pause` container owns and why containers in a Pod share one IP.
7. Distinguish `ErrImagePull` from `ImagePullBackOff` and name three distinct root causes behind them.
8. Explain why a rebuilt image can still run *stale* in kind, and the two ways to force the new bytes.
9. Diagnose an `exec format error` and fix it with a one-line `buildx --platform` build.
10. Find the fattest layer in a bloated image with `docker history` and say why `rm` in a later `RUN` doesn't shrink it.

➡ Next up: **Pods, Deployments & the Reconciliation Loop** — how Kubernetes turns that image into a self-healing, rolling-updatable workload, and the three probes that decide whether it lives, dies, or silently black-holes traffic.
