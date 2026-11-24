# Docker Internals & Mastery — Course 37 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `course-37-docker-internals` — a standalone Docker deep-dive course with 11 modules and 15 challenges covering Linux internals, building a container runtime from scratch, and running your own registry.

**Architecture:** A new course directory under `courses/course-37-docker-internals/` following the CONTENT_SPEC.md contract exactly. Modules are standalone `.md` files with ASCII diagrams and runnable commands. Challenges follow the full challenge directory structure (challenge.json, brief.md, solution.md, hints.json, setup.sh, verify.sh/flag.sha256).

**Tech Stack:** Markdown, Bash, Docker CLI, `unshare`, `nsenter`, `pivot_root`, `distribution` (registry:2), `cosign`, `buildx`

**Spec:** `CONTENT_SPEC.md` in repo root — the platform contract every file must satisfy.

## Global Constraints

- Course ID must equal directory name: `course-37-docker-internals`
- Flag format: `KUBE{lower_snake_case}` — tokens must read as the lesson
- `flag.sha256` generated with: `printf '%s' 'KUBE{...}' | shasum -a 256 | awk '{print $1}'`
- `setup.sh`: `set -euo pipefail`, idempotent (`kubectl apply`), namespace `dojo-docker-*`
- `verify.sh`: `set -uo pipefail`, `fail()` helper, only `kubectl` + POSIX (no `jq`)
- Audience: SDE who already knows basic Dockerfiles — skip "what is a container", go deep on the why
- Language: easy, conversational — explain WHY before HOW
- Images pinned to tags (never `:latest`)
- Module titles are the first `#` heading in the file

## Flags (verbatim — do not change these)

| Challenge slug | Flag |
|---|---|
| 01-fat-image-diet | `KUBE{layer_order_saves_rebuild_time}` |
| 02-cache-busted | `KUBE{cache_busted_by_volatile_copy}` |
| 03-entrypoint-trap | `KUBE{entrypoint_runs_cmd_as_args}` |
| 04-multi-stage-go | `KUBE{distroless_binary_no_shell}` |
| 05-cross-platform | `KUBE{buildx_platform_linux_amd64}` |
| 06-namespace-spelunker | `KUBE{namespaces_isolate_kernel_views}` |
| 07-cgroup-enforcer | `KUBE{cgroup_throttles_at_the_kernel}` |
| 08-network-detective | `KUBE{iptables_rules_docker_network}` |
| 09-volume-leakage | `KUBE{volume_persists_across_restart}` |
| 10-security-lockdown | `KUBE{drop_all_caps_read_only_safe}` |
| 11-distroless-debug | `KUBE{ephemeral_debug_distroless_pod}` |
| 12-bare-metal-container | `KUBE{unshare_pivot_root_no_docker}` |
| 13-image-signing | `KUBE{cosign_signs_oci_supply_chain}` |
| 14-custom-bridge | `KUBE{custom_bridge_isolates_traffic}` |
| 15-registry-boss | `KUBE{own_registry_serves_the_dojo}` |

## Review Focus

- `setup.sh` idempotency: re-running must not error (use `kubectl apply`, not `create`)
- `verify.sh` no-jq rule: all JSON parsing via `-o jsonpath`, not `jq`
- Namespace naming: all namespaces must be `dojo-docker-*` (not `dojo-*` for other courses)
- flag.sha256 correctness: use `printf '%s'` (no newline) — `echo` adds `\n` and breaks the hash
- Module ordering: first `#` heading = module title shown in platform; every module file starts with that heading

---

## Task 0: Course scaffold + flag hashes

**Files:**
- Create: `courses/course-37-docker-internals/course.json`
- Create: `courses/course-37-docker-internals/modules/` (dir)
- Create: `courses/course-37-docker-internals/challenges/` (dir)
- Create: all 15 `flag.sha256` files (one per challenge)

- [ ] Create `courses/course-37-docker-internals/course.json`:
```json
{
  "id": "course-37-docker-internals",
  "slug": "docker-internals",
  "title": "Docker Internals & Mastery",
  "order": 37,
  "status": "available",
  "difficulty": "Intermediate → Advanced",
  "estHours": "20–25 h",
  "prereqs": ["Basic Dockerfiles", "Linux command line", "course-01 Module 02 recommended"],
  "tags": ["docker", "containers", "linux", "internals", "registry", "security"],
  "description": "Go from Docker user to Docker understander. Linux namespaces, cgroups, OverlayFS, Dockerfile mastery, networking internals, container security, building a container runtime from scratch, and running your own private registry — 11 modules and 15 hands-on challenges."
}
```

- [ ] Generate all flag.sha256 files using `printf '%s' 'KUBE{...}' | shasum -a 256 | awk '{print $1}'` for each flag in the flags table above.

- [ ] Commit: `git add courses/course-37-docker-internals/course.json && git commit -m "feat: scaffold course-37 Docker Internals — course.json + flag hashes"`

---

## Task 1: Modules 01–04 (Internals foundations)

**Files:**
- Create: `courses/course-37-docker-internals/modules/01-docker-architecture.md`
- Create: `courses/course-37-docker-internals/modules/02-linux-namespaces.md`
- Create: `courses/course-37-docker-internals/modules/03-cgroups-resource-control.md`
- Create: `courses/course-37-docker-internals/modules/04-overlayfs-image-layers.md`

### 01-docker-architecture.md — "How Docker Actually Works"
Cover: docker CLI → dockerd → containerd → containerd-shim → runc pipeline. CRI. What `docker run` does step by step. The `pause` container. ASCII diagram showing the full call chain. Easy language: "Think of dockerd as a manager, containerd as the worker, and runc as the one who actually does the work."

ASCII diagram required:
```
docker CLI
    │
    ▼  (REST over unix socket)
 dockerd
    │
    ▼  (gRPC)
 containerd
    │
    ├──► image store (pull, unpack)
    │
    └──► containerd-shim
              │
              ▼
            runc (creates namespaces + cgroups + rootfs → exec PID 1)
```

Checkpoint: 8 questions readers should be able to answer without looking things up.

### 02-linux-namespaces.md — "The Walls That Make a Container"
Cover: the 8 namespace types (mnt, pid, net, ipc, uts, user, cgroup, time). What each one isolates. How to list namespaces: `lsns`, `/proc/PID/ns/`. How to enter: `nsenter`. How Docker creates them: `clone(CLONE_NEWPID | CLONE_NEWNET | ...)`. Show `/proc/1/ns` vs `/proc/<container-pid>/ns` diff. Easy analogy: "A namespace is like giving a process its own view of the world — it thinks it's the only process, the only network, the only filesystem."

ASCII diagram showing "host view" vs "container view" of namespaces.

Practical commands:
```bash
# list all namespaces on the host
lsns
# see a container's namespaces
docker inspect <id> --format '{{.State.Pid}}' 
ls -la /proc/<pid>/ns/
# enter the network namespace of a running container
nsenter -t <pid> -n ip addr
```

### 03-cgroups-resource-control.md — "How Docker Limits Resources"
Cover: cgroups v1 vs v2. The `/sys/fs/cgroup` filesystem. CPU (cpu.max), memory (memory.max, memory.swap.max), pids (pids.max). How `docker run --cpus 0.5 --memory 128m` translates to cgroup writes. OOM killer. How to read a container's cgroup limits live.

Easy analogy: "cgroups are like a budget — the kernel enforces spending limits so one container can't take everything."

Practical:
```bash
# find a container's cgroup
docker inspect <id> --format '{{.HostConfig.CgroupParent}}'
cat /sys/fs/cgroup/system.slice/docker-<id>.scope/memory.max
cat /sys/fs/cgroup/system.slice/docker-<id>.scope/cpu.max
# trigger OOM and observe
docker run --memory=50m ubuntu bash -c 'cat /dev/zero | head -c 100m > /dev/null'
```

### 04-overlayfs-image-layers.md — "What's Actually on Disk"
Cover: OverlayFS mechanics (lowerdir, upperdir, workdir, merged). How image layers map to lowerdir. Where Docker stores layers: `/var/lib/docker/overlay2/`. CoW: file read vs file write. How to inspect layers manually. `docker history`. Why `rm` in a later RUN doesn't shrink the image.

ASCII diagram:
```
merged/   ← what the container sees (union of all)
    │
    ├── upperdir/   ← writable, per-container (deleted on container removal)
    ├── workdir/    ← internal OverlayFS bookkeeping
    └── lowerdir/   ← read-only, stacked image layers (bottom = base image)
            layer4 (your app code)
            layer3 (pip install)
            layer2 (apt-get install)
            layer1 (base OS)
```

Practical:
```bash
docker image inspect nginx:1.27-alpine --format '{{json .GraphDriver}}'
ls /var/lib/docker/overlay2/
# see the merged view of a running container
docker inspect <id> --format '{{.GraphDriver.Data.MergedDir}}'
ls $(docker inspect <id> --format '{{.GraphDriver.Data.MergedDir}}')
```

- [ ] Commit: `git add courses/course-37-docker-internals/modules/0{1,2,3,4}-*.md && git commit -m "feat: course-37 modules 01-04 — Docker architecture, namespaces, cgroups, OverlayFS"`

---

## Task 2: Modules 05–07 (Build + Networking)

**Files:**
- Create: `courses/course-37-docker-internals/modules/05-dockerfile-mastery.md`
- Create: `courses/course-37-docker-internals/modules/06-multi-stage-and-minimal.md`
- Create: `courses/course-37-docker-internals/modules/07-docker-networking.md`

### 05-dockerfile-mastery.md — "Writing Dockerfiles That Don't Waste Your Time"
Go deeper than course-01. Cover: ARG vs ENV (ARG is build-time only, ENV persists); SHELL form vs exec form (why `CMD ["node"]` not `CMD node`); HEALTHCHECK; ONBUILD; BuildKit cache mounts (`--mount=type=cache`); heredoc syntax; .dockerignore patterns. Full ARG/ENV/ENTRYPOINT/CMD matrix table.

### 06-multi-stage-and-minimal.md — "Ship Less, Attack Less"
Cover: multi-stage mechanics, named stages, `--target`, partial builds. Distroless images (what's in them, what's not). `scratch` for static binaries. Alpine gotchas (musl vs glibc). Image size comparison table. `dive` for layer inspection. BuildKit secrets (`--secret`).

### 07-docker-networking.md — "Packets and Plumbing"
Cover: network drivers (bridge, host, none, overlay, macvlan). Linux bridge (`docker0`). veth pairs (how each container gets a virtual ethernet). iptables rules Docker injects (DOCKER chain, MASQUERADE, DNAT). DNS inside containers (`127.0.0.11`). Custom networks and DNS. `docker network inspect`. Port publishing mechanics.

ASCII diagram — packet path from container to internet:
```
container eth0 (veth pair end)
    │
    ▼
host vethXXX (other end of pair, attached to docker0 bridge)
    │
    ▼
docker0 bridge (172.17.0.1)
    │
    ▼  (iptables MASQUERADE in POSTROUTING)
host eth0 (your physical NIC, real IP)
    │
    ▼
internet
```

- [ ] Commit modules 05–07.

---

## Task 3: Modules 08–11 (Storage, Security, Runtime, Registry)

**Files:**
- Create: `courses/course-37-docker-internals/modules/08-volumes-and-storage.md`
- Create: `courses/course-37-docker-internals/modules/09-container-security.md`
- Create: `courses/course-37-docker-internals/modules/10-build-your-own-runtime.md`
- Create: `courses/course-37-docker-internals/modules/11-docker-registry-boss.md`

### 08-volumes-and-storage.md — "Where Data Lives"
Cover: named volumes vs bind mounts vs tmpfs. Where named volumes live on disk. Storage drivers (overlay2 is default; why). Volume drivers. `docker volume inspect`. When to use each. Pitfalls: writing to container layer, volume mount precedence.

### 09-container-security.md — "What Stops a Container Escaping"
Cover: Linux capabilities (what they are, `capsh --print`, which Docker drops by default). seccomp (the default Docker profile blocks 44 syscalls, why). AppArmor. rootless Docker. `--privileged` and why it's dangerous. User namespace remapping. The full `docker run --cap-drop ALL --cap-add NET_BIND_SERVICE --security-opt no-new-privileges` pattern explained line by line.

### 10-build-your-own-runtime.md — "Containers Without Docker"
This is the crown jewel module. Walk through creating a container from scratch using only Linux primitives. Easy language: step by step, each command explained.

Steps:
1. Get a rootfs: `docker export $(docker create alpine) | tar -xC /tmp/my-rootfs/`
2. Create namespaces: `unshare --mount --pid --net --ipc --uts --fork`
3. Mount /proc: `mount -t proc proc /tmp/my-rootfs/proc`
4. Mount /dev, /sys
5. `pivot_root` to the new rootfs (or `chroot` as simpler alt)
6. Run a process as PID 1: `exec sh`

Then: add cgroups manually (write to `/sys/fs/cgroup`). Show the full script that creates a "container" in ~30 lines of bash.

Final: explain what runc does that our script doesn't (OCI runtime spec, hook system, etc.).

### 11-docker-registry-boss.md — "Run the Registry Others Push To"
Cover: OCI Distribution Spec (the HTTP API). `GET /v2/`, `/v2/<name>/tags/list`, `/v2/<name>/manifests/<ref>`, `/v2/<name>/blobs/<digest>`. Run `registry:2` locally. Add TLS. Add htpasswd auth. `docker login`. Push and pull. Configure kind to trust and use it. Harbor as production-grade option (brief overview).

- [ ] Commit modules 08–11.

---

## Task 4: Challenges 01–05 (Easy/Medium — build efficiency)

Each challenge needs: `challenge.json`, `brief.md`, `solution.md`, `hints.json`, `setup.sh`, `verify.sh` (verifier) or no verify.sh (discovery), `flag.sha256`.

### 01-fat-image-diet (Easy, verifier)
**Setup:** Deploy a Pod running a fat nginx-based image (simulate with a Dockerfile baked in) OR just check that the learner builds a correctly optimized image meeting criteria. Actually: simpler — have setup.sh plant a Deployment using a known "wrong" image pattern, verifier checks the learner rebuilt it correctly. Or make it discovery: embed the flag in Docker image labels.

**Better approach (discovery):** setup.sh builds a fat image with wrong layer order and embeds the flag in an image label. Learner must: (a) find the fat layer with `docker history`, (b) identify the bad instruction order, (c) rebuild with correct order. Flag is `docker inspect` of the rebuilt image's label (which we set via ARG propagated from the fixed Dockerfile). 

Actually even simpler: setup.sh pushes a Docker image to the local kind registry with the flag hidden in a layer. Learner uses `docker history` / layer inspection to find it. This is a **discovery** challenge.

**Flag:** `KUBE{layer_order_saves_rebuild_time}` — discovery type. Flag is embedded as an image label in a provided container image. Learner must inspect image history/labels.

### 02-cache-busted (Easy, verifier)
**Setup:** Deploy a Pod from an image. The Deployment has an annotation showing build time. Learner must rebuild the image with correct Dockerfile order so that only source changes (not dependency install) bust the cache. Verifier checks Pod annotation for new build time AND that the image rebuild time for a "code-only" change is under a threshold. 

Actually, make it simpler for K8s context: setup.sh creates a ConfigMap with a "build log" showing the broken pattern, plants a Dockerfile in a ConfigMap. Learner fixes the Dockerfile, proves cache works. Flag is in a Secret revealed when verify.sh finds the correct Dockerfile pattern applied. **Verifier** type.

### 03-entrypoint-trap (Easy, discovery)
Setup.sh creates a Pod that immediately exits (wrong ENTRYPOINT/CMD). Flag is in Pod logs once the learner fixes it and it runs correctly. **Verifier** type checking pod Running + correct output.

### 04-multi-stage-go (Medium, verifier)
Setup provides a Go app source (in a ConfigMap or planted file). Learner builds it using multi-stage build, final image on distroless, pushes to local kind registry, deploys as a Pod. Verifier checks: image size < 20MB, Pod Running, no shell in image.

### 05-cross-platform (Medium, verifier)
Setup plants a Deployment that fails with `exec format error` (wrong arch). Learner diagnoses, rebuilds with correct `--platform`. Verifier checks Pod Running and correct arch annotation.

- [ ] Commit challenges 01–05.

---

## Task 5: Challenges 06–10 (Medium — internals)

### 06-namespace-spelunker (Medium, discovery)
Setup.sh starts a container with `docker run -d` on the host, hides the flag in a file inside the container's mount namespace. Learner must find the container's PID, use `nsenter` to enter its mount namespace without `docker exec`, find the flag. Flag format: discovery.

### 07-cgroup-enforcer (Medium, verifier)
Setup.sh creates a Pod with NO resource limits. Verifier checks the learner has applied correct resource limits (cpu.max, memory.max readable from cgroup). Learner must set requests/limits AND verify via cgroup filesystem path. Flag revealed when both cgroup limits AND pod Running.

### 08-network-detective (Medium, verifier)
Setup.sh creates two pods in different custom Docker networks (using network policies / separate namespaces). One can reach a service, one can't. Learner diagnoses with `iptables -L` / `docker network inspect` / `nsenter -n`. Fixes by connecting container to correct network. Verifier checks connectivity.

### 09-volume-leakage (Easy, verifier)
Setup.sh creates a Pod writing to a container-layer path (not a Volume). Data disappears on restart. Learner must add a PersistentVolumeClaim / emptyDir Volume and mount at the correct path. Verifier checks file persists across pod restart.

### 10-security-lockdown (Medium, verifier)
Setup.sh creates a Pod running as root with ALL capabilities. Verifier checks: runAsNonRoot=true, allowPrivilegeEscalation=false, readOnlyRootFilesystem=true, capabilities.drop=["ALL"], seccompProfile.type=RuntimeDefault. Learner patches the Deployment to satisfy all checks.

- [ ] Commit challenges 06–10.

---

## Task 6: Challenges 11–15 (Hard/Insane — advanced)

### 11-distroless-debug (Hard, verifier)
Setup.sh deploys a distroless container that is crashlooping. Learner must use `kubectl debug` with an ephemeral container to attach a debug toolbox, diagnose the issue, fix the deployment. No `kubectl exec sh` allowed (there's no shell). Verifier checks Pod Running after fix.

### 12-bare-metal-container (Hard, discovery)
No K8s. Pure Linux. Setup.sh provides a rootfs tarball at `/tmp/dojo-rootfs.tar`. Learner must create a running container using ONLY `unshare`, `chroot`/`pivot_root`, and manual `/proc` mount. Flag is embedded in `/flag.txt` inside the rootfs — only readable if you've correctly entered the namespace + rootfs. **Discovery** (learner reads the file once their "container" is running).

### 13-image-signing (Hard, verifier)
Setup.sh deploys a pod from an unsigned image. Learner installs cosign, signs the image, pushes the signature to the registry. Verifier checks signature exists in registry and is valid for the image digest.

### 14-custom-bridge (Hard, verifier)
Setup.sh creates containers on `bridge` network. Learner creates an isolated custom Docker network, moves containers, proves `--network custom-net` containers can reach each other but NOT the default bridge. Verifier checks: custom network exists, containers attached, isolation confirmed via iptables.

### 15-registry-boss (Insane, verifier)
The boss challenge. Setup.sh prepares a kind cluster with nothing in a local registry. Learner must:
1. Deploy `registry:2` as a Pod in `dojo-docker-registry` namespace
2. Configure it with htpasswd auth (username: `dojo`, password: `docker-master`)
3. Push an image to it from outside the cluster
4. Create an `imagePullSecrets` Secret
5. Deploy a Pod that pulls from the registry
Verifier checks: registry Pod running, target Pod running with image from `localhost:5000/dojo/*`.

- [ ] Commit challenges 11–15.

---

## Task 7: Final commit + push

- [ ] `git add -A courses/course-37-docker-internals/`
- [ ] `git commit -m "feat: add course-37 Docker Internals & Mastery — 11 modules + 15 challenges"`
- [ ] `git push origin main`
- [ ] Send email to aadarsh24lv@gmail.com via mailer skill: "course-37 Docker Internals shipped — 11 modules, 15 challenges, committed and pushed"
