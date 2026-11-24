# How Docker Actually Works

> **Module 01 · Course 37** — You've been using Docker for a while. You know `docker build`, `docker run`, `docker push`. But what actually happens when you type those commands? Who does the work? This module tears open the black box and shows you every component in the chain — so the next time something breaks, you know exactly where to look.

---

## The Big Picture: It's Not One Thing

Here's something most people don't realize: **"Docker" is at least five separate programs talking to each other**. When you run `docker run nginx`, you're not just starting one process. You're kicking off a chain of calls across multiple binaries.

```
docker CLI
    │  REST over /var/run/docker.sock
    ▼
  dockerd  (the Docker daemon — your config, auth, volumes, networks)
    │  gRPC
    ▼
containerd  (the lifecycle manager — pull images, create/start/stop containers)
    │
    ├──► image store  (pull manifest, download layer blobs, unpack)
    │
    └──► containerd-shim  (stays alive between containerd restarts, owns stdio)
              │
              ▼
            runc  (creates namespaces + cgroups, calls clone(), execs PID 1)
              │
              ▼
        your process  (PID 1 inside the container)
```

Let's walk through each one.

---

## The Docker CLI

The `docker` command you type is just a **thin client**. It takes your command, translates it into a REST API call, and sends it over a Unix socket at `/var/run/docker.sock`.

```bash
# Every docker command is a REST call under the hood.
# You can even use curl directly:
curl --unix-socket /var/run/docker.sock \
  http://localhost/v1.47/containers/json | python3 -m json.tool
```

The CLI does no container work itself. It's just a pretty interface that talks to dockerd.

---

## dockerd — The Docker Daemon

`dockerd` is the main Docker daemon. It owns:
- Your **volume** definitions
- Your **network** definitions
- **Image** metadata and pull credentials
- **Authentication** (imagePullSecrets, `docker login` tokens)
- The **API** that the CLI talks to

When you `docker run nginx`, dockerd receives the REST request, checks your local image store, and if the image isn't present — goes to pull it. Once the image is ready, it hands off to **containerd** to actually do the lifecycle work.

Think of dockerd as the **manager** that knows your preferences and config, but delegates the real work.

---

## containerd — The Container Lifecycle Manager

containerd is the **workhorse**. It was originally part of Docker, then extracted into a standalone CNCF project because Kubernetes (and others) needed a container runtime they could use without Docker.

containerd is responsible for:
- **Pulling images**: fetching manifest, downloading layer blobs, verifying checksums
- **Unpacking images**: decompressing layers into an overlay filesystem rootfs
- **Starting containers**: calling into runc via the shim
- **Managing state**: tracking which containers are running, paused, stopped
- **Snapshots**: the abstraction over the storage driver (overlay2, etc.)

```bash
# containerd has its own CLI: ctr
# (usually only used for debugging, not day-to-day use)
ctr images list
ctr containers list
ctr tasks list
```

Inside a Kubernetes node, `containerd` talks directly to the kubelet via the **CRI** (Container Runtime Interface — a gRPC protocol). dockerd is not in that path at all in modern K8s.

---

## containerd-shim — The Silent Keeper

Here's something subtle: when containerd restarts (say, during an upgrade), your running containers should not die. The **shim** solves this.

For every running container, containerd spawns a `containerd-shim` process. The shim:
1. **Stays alive** even if containerd restarts
2. **Owns the container's stdio** (stdin, stdout, stderr pipes)
3. **Reports exit status** back to containerd when the container finishes
4. **Calls runc** to actually create the container

```bash
# You can see shims running:
ps aux | grep containerd-shim
# output: containerd-shim-runc-v2 -namespace moby -id <container-id> -address ...
```

Think of the shim as a **babysitter** — it watches the container on behalf of containerd, so the daemon can be restarted without orphaning the child.

---

## runc — The One Who Actually Does the Work

`runc` is the low-level **OCI runtime**. It:
1. Reads the OCI runtime spec (`config.json`) that containerd-shim prepared
2. Calls `clone(2)` with the right namespace flags to create namespaces
3. Sets up cgroups for resource limits
4. Mounts the overlay filesystem as the rootfs
5. Drops capabilities (security hardening)
6. Calls `execve()` to start your process as PID 1

After `runc` does its job, **it exits**. The container process runs directly — not as a child of runc. The shim is the parent.

```bash
# runc is a standalone binary you can call directly
runc --help
# In production: containerd-shim calls it; you rarely invoke it yourself
```

runc implements the **OCI Runtime Specification** — an open standard. Alternative runtimes (gVisor's `runsc`, Kata Containers' `kata-runtime`) implement the same spec but with different isolation models.

---

## What Happens on `docker run nginx:1.27-alpine`

Step by step, every time:

```
1. docker CLI  →  POST /v1.47/containers/create  →  dockerd

2. dockerd checks local image store:
   - Image present? Skip to step 5.
   - Not present? Go to step 3.

3. dockerd calls containerd: "pull nginx:1.27-alpine from docker.io"

4. containerd:
   a. GET /v2/library/nginx/manifests/1.27-alpine  (fetch manifest)
   b. For each layer: GET /v2/library/nginx/blobs/<digest>  (download)
   c. Verify sha256 of each layer
   d. Unpack layers into /var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/

5. dockerd calls containerd: "create container with this spec"

6. containerd-shim is spawned by containerd

7. shim calls runc:
   a. runc creates namespaces: clone(CLONE_NEWPID | CLONE_NEWNET | CLONE_NEWMNT | ...)
   b. runc sets up cgroups: writes to /sys/fs/cgroup/...
   c. runc mounts overlay filesystem as rootfs
   d. runc drops capabilities per the spec
   e. runc calls execve("/docker-entrypoint.sh") — PID 1 in the container

8. runc exits. Container process runs. Shim watches it.

9. dockerd returns container ID to CLI.
10. docker CLI prints the ID (or streams logs if -it or --attach).
```

---

## ENTRYPOINT vs CMD — At the Kernel Level

Both ENTRYPOINT and CMD end up in the OCI spec as the `args` to `execve()`.

- **ENTRYPOINT** is the executable
- **CMD** is the default arguments

When runc runs the container, it calls:
```
execve(ENTRYPOINT[0], ENTRYPOINT + CMD, env)
```

If you set `CMD` only (no ENTRYPOINT), the shell form uses `/bin/sh -c`, making `sh` PID 1 — not your app. That's why signals break. The exec form `CMD ["node", "server.js"]` avoids sh entirely.

```dockerfile
# Shell form — /bin/sh is PID 1, node is a child
CMD node server.js
# → execve("/bin/sh", ["/bin/sh", "-c", "node server.js"], ...)

# Exec form — node is PID 1, receives signals directly
CMD ["node", "server.js"]
# → execve("/usr/local/bin/node", ["node", "server.js"], ...)
```

This matters for `docker stop`: it sends `SIGTERM` to PID 1. If PID 1 is `sh`, your app never sees the signal.

---

## docker stop — The Graceful Shutdown Chain

```
docker stop <container>
    │
    ▼
dockerd sends SIGTERM to PID 1 in the container
    │
    ├── App handles SIGTERM and exits cleanly  ← happy path
    │
    └── After --stop-timeout seconds (default: 10):
        dockerd sends SIGKILL  ← forced kill
```

If your app needs more than 10 seconds to drain connections and flush data, set `--stop-timeout` or the `STOPSIGNAL` Dockerfile instruction to match what your app listens for.

---

## The pause Container (K8s Context)

In Kubernetes, every Pod has a container you never see: the **pause container** (also called the "infra container"). It's a tiny process (`gcr.io/google_containers/pause:3.9`) that does nothing except hold the Pod's Linux **namespaces** open.

```
                   Pod
   ┌───────────────────────────────────────────┐
   │  pause container  (holds namespaces)        │
   │   - net namespace  → all containers share   │
   │   - ipc namespace  → all containers share   │
   │   - uts namespace  → all containers share   │
   │                                             │
   │  app container A  (joins pause namespaces)  │
   │  app container B  (joins pause namespaces)  │
   └───────────────────────────────────────────┘
```

App containers **join** the pause container's namespaces. That's why every container in a Pod sees the same `localhost`, the same network interface, and the same IPC semaphores — they're literally sharing kernel objects.

---

## Docker Was Removed from Kubernetes (But Your Images Still Work)

Kubernetes 1.24 removed `dockershim` — the adapter that let the kubelet talk to dockerd. The kubelet now talks directly to containerd (or CRI-O) via the CRI protocol.

**What changed:** The kubelet no longer uses dockerd.
**What didn't change:** The OCI image format. Images you build with `docker build` are OCI images, and containerd reads them natively. Your Dockerfiles keep working.

```
Before K8s 1.24:   kubelet → dockershim → dockerd → containerd → runc
After K8s 1.24:    kubelet → CRI → containerd → runc
```

The takeaway: `dockerd` is for your developer workflow. The cluster doesn't need it.

---

## Checkpoint

You're done with this module when you can answer these without looking anything up:

1. Name the five components in the `docker run` call chain and what each one does.
2. What does the containerd-shim exist to solve? What would happen without it?
3. What does runc do, and when does it exit?
4. Why does `CMD node server.js` (shell form) break signal forwarding, and what's the fix?
5. What is `/var/run/docker.sock` and what protocol runs over it?
6. What is the CRI, and which Kubernetes version removed the dockershim?
7. What does the pause container do in a Kubernetes Pod?
8. Where are layer blobs stored on disk after `docker pull`?
9. What syscall does runc call to create namespaces, and what flags does it pass?
10. In what order does `docker stop` send signals, and what is the default timeout?

➡ Next up: **Linux Namespaces** — the kernel mechanism that makes containers feel isolated, examined one type at a time.
