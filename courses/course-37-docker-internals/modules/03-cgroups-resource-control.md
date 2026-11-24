# cgroups — How the Kernel Enforces Resource Limits

> **Module 03 · Course 37** — Namespaces give containers isolation. But what stops one container from using 100% of your CPU or eating all your memory? That's cgroups. If namespaces are the **walls**, cgroups are the **budget**. This module shows you how Docker translates `--cpus 0.5 --memory 128m` into actual kernel-enforced limits — and how to read and verify them live.

---

## What Are cgroups?

**cgroups** (control groups) is a Linux kernel feature that organizes processes into a hierarchy and applies resource limits, accounting, and control to each group.

The key insight: **cgroups look like files**. The kernel exposes the entire cgroup API through a virtual filesystem at `/sys/fs/cgroup/`. You set limits by writing to files. You read usage by reading files. No special syscalls needed — just standard file I/O.

```bash
# cgroups are a filesystem
ls /sys/fs/cgroup/
# cgroup.controllers  cgroup.procs  cpu.stat  memory.stat
# system.slice/  user.slice/  ...

# This is a kernel virtual filesystem — writes go to the kernel, not disk
file /sys/fs/cgroup/
# /sys/fs/cgroup/: directory
mount | grep cgroup
# cgroup2 on /sys/fs/cgroup type cgroup2 (rw,nosuid,nodev,noexec,relatime)
```

---

## cgroups v1 vs v2

There are two versions. cgroups v1 (the original) has a messy design where each resource type had its own hierarchy. cgroups v2 (unified hierarchy) puts everything under one tree. Modern Linux (kernel 4.5+, and default on Ubuntu 22.04+, Debian 11+, Fedora 31+) uses **cgroups v2**.

```
cgroups v1 (old, messy):                cgroups v2 (unified, clean):
─────────────────────────               ──────────────────────────────
/sys/fs/cgroup/                         /sys/fs/cgroup/
  cpu/                                    system.slice/
    system.slice/                           docker-<id>.scope/
      docker-<id>/                            cgroup.procs
  memory/                                     cpu.max
    system.slice/                             memory.max
      docker-<id>/                            pids.max
  pids/                                       io.max
    ...
```

With v1 you had to find separate directories per resource type. With v2, one directory per container holds everything.

**Check which version you have:**
```bash
grep cgroup /proc/filesystems
# nodev cgroup
# nodev cgroup2   ← if this line exists, v2 is supported

stat -f /sys/fs/cgroup/
# ID: 63 — 0x63 = 'c' in ASCII... but easier to check:
cat /sys/fs/cgroup/cgroup.controllers
# cpuset cpu io memory hugetlb pids rdma misc  ← v2 output
```

---

## The Docker → cgroup Translation

When you run `docker run --cpus 0.5 --memory 128m nginx`, the Docker daemon writes to these kernel files:

```
docker run --cpus 0.5 --memory 128m nginx
      │
      ▼  (docker daemon translates)
/sys/fs/cgroup/
  └── system.slice/
      └── docker-<container-id>.scope/
          ├── cpu.max          → "50000 100000"   (50% of 1 CPU)
          ├── memory.max       → "134217728"      (128 MiB in bytes)
          ├── memory.swap.max  → "0"              (no swap)
          └── pids.max         → "max"            (unlimited unless set)
```

Let's decode each file:

---

## CPU Limits: cpu.max

`cpu.max` has the format `<quota> <period>`, both in microseconds.

```
"50000 100000"
  │       │
  │       └── period: 100ms (100000 µs) — the measurement window
  └────────── quota: 50ms (50000 µs) — max CPU time per period
```

Translation: in every 100ms window, this cgroup can use at most 50ms of CPU = **50% of one CPU**.

```bash
# Start a container with CPU limit
docker run -d --cpus 0.5 --name cpu-test nginx:1.27-alpine

# Find the cgroup path
CID=$(docker inspect cpu-test --format '{{.Id}}')
CGROUP_PATH="/sys/fs/cgroup/system.slice/docker-${CID}.scope"

# Read the limit
cat $CGROUP_PATH/cpu.max
# 50000 100000

# Read current CPU usage (cumulative microseconds)
cat $CGROUP_PATH/cpu.stat
# usage_usec 123456
# user_usec 100000
# system_usec 23456

# Docker cleanup
docker rm -f cpu-test
```

**Common values:**
| docker --cpus | cpu.max |
|---|---|
| `--cpus 0.25` | `25000 100000` |
| `--cpus 0.5` | `50000 100000` |
| `--cpus 1` | `100000 100000` |
| `--cpus 2` | `200000 100000` |
| (no limit) | `max 100000` |

---

## Memory Limits: memory.max and memory.swap.max

Memory limits are simpler — just bytes.

```bash
# 128 MiB = 128 × 1024 × 1024 = 134217728 bytes
docker run -d --memory 128m --name mem-test nginx:1.27-alpine

CID=$(docker inspect mem-test --format '{{.Id}}')
CGROUP_PATH="/sys/fs/cgroup/system.slice/docker-${CID}.scope"

# Memory limit
cat $CGROUP_PATH/memory.max
# 134217728

# Swap limit (0 = no swap allowed)
cat $CGROUP_PATH/memory.swap.max
# 0

# Current memory usage
cat $CGROUP_PATH/memory.current
# 7340032  (about 7MB for nginx at idle)

# Peak usage since start
cat $CGROUP_PATH/memory.peak
# 12582912  (12MB peak)

docker rm -f mem-test
```

---

## The OOM Killer

When a container exceeds its memory limit, the kernel's **OOM killer** steps in. It kills processes inside the cgroup until memory is freed.

```bash
# Watch the OOM killer in action (safe — it only kills the container)
docker run --memory=50m --name oom-test alpine \
  sh -c 'cat /dev/zero | head -c 100m > /dev/null'
# Container gets killed. Exit code 137 (128 + SIGKILL).
echo "Exit code: $?"

# OOM events are recorded in the cgroup
docker events --filter container=oom-test
# ... container oom  (or check dmesg on the host)

docker rm -f oom-test 2>/dev/null || true
```

```bash
# In Kubernetes, an OOM-killed pod shows:
kubectl describe pod <name>
# State: OOMKilled
# Exit Code: 137
```

---

## PID Limits: pids.max

A **fork bomb** (`:(){ :|:& };:`) can crash a system by creating processes until the host runs out of PIDs. `pids.max` caps how many processes can exist in the cgroup.

```bash
# Default Docker: 0 = use kernel default (usually unlimited)
docker run -d --pids-limit 50 --name pid-test alpine sleep 3600

CID=$(docker inspect pid-test --format '{{.Id}}')
cat /sys/fs/cgroup/system.slice/docker-${CID}.scope/pids.max
# 50

# Try to exceed it
docker exec pid-test sh -c 'for i in $(seq 1 100); do sleep 100 & done'
# bash: fork: retry: No child processes (stops at ~50)

docker rm -f pid-test
```

---

## Kubernetes Resource Limits and cgroups

Kubernetes resource limits map directly to cgroups too — via the kubelet:

```yaml
# K8s pod spec
resources:
  limits:
    cpu: "500m"     # 0.5 CPU
    memory: "128Mi"
  requests:
    cpu: "100m"
    memory: "64Mi"
```

```bash
# This translates to the same cgroup files, in the K8s cgroup hierarchy:
# /sys/fs/cgroup/kubepods/burstable/pod<pod-uid>/<container-id>/

# On a kind node, peek inside:
docker exec dojo-control-plane \
  cat /sys/fs/cgroup/kubepods.slice/cpu.stat
```

The difference: **requests** affect scheduling (the scheduler uses them to find a node with enough room). **limits** are enforced by the kernel via cgroups at runtime.

**QoS classes and cgroups:**
- `Guaranteed` (requests == limits): placed in `kubepods/guaranteed/`
- `Burstable` (requests < limits): placed in `kubepods/burstable/`
- `BestEffort` (no requests or limits): placed in `kubepods/besteffort/` — first to be OOM-killed

---

## Reading cgroup Stats Live

```bash
# Start a container doing some work
docker run -d --cpus 1 --memory 256m --name stats-test \
  nginx:1.27-alpine

CID=$(docker inspect stats-test --format '{{.Id}}')
CPATH="/sys/fs/cgroup/system.slice/docker-${CID}.scope"

# Poll stats every second
watch -n1 "
echo '=== CPU ===';
cat $CPATH/cpu.max;
cat $CPATH/cpu.stat | head -3;
echo '=== Memory ===';
cat $CPATH/memory.current;
echo '=== PIDs ===';
cat $CPATH/pids.current;
"

docker rm -f stats-test
```

---

## Writing to cgroups Manually

You can create a cgroup and add any process to it:

```bash
# Create a new cgroup (just make a directory)
sudo mkdir /sys/fs/cgroup/my-experiment

# Enable CPU and memory controllers (inherit from parent)
echo "+cpu +memory +pids" | sudo tee /sys/fs/cgroup/my-experiment/cgroup.subtree_control

# Set a 25% CPU limit
echo "25000 100000" | sudo tee /sys/fs/cgroup/my-experiment/cpu.max

# Set a 64MB memory limit
echo "67108864" | sudo tee /sys/fs/cgroup/my-experiment/memory.max

# Add your current shell to this cgroup
echo $$ | sudo tee /sys/fs/cgroup/my-experiment/cgroup.procs

# Verify
cat /proc/$$/cgroup
# 0::/my-experiment

# Now this shell and all its children are limited!
# Clean up: move out first, then remove
echo 1 | sudo tee /sys/fs/cgroup/init.scope/cgroup.procs
sudo rmdir /sys/fs/cgroup/my-experiment
```

This is essentially what runc does for every container. No special binary — just file writes.

---

## cgroup Hierarchy in Practice

```
/sys/fs/cgroup/
├── cgroup.controllers   ← available controllers
├── cgroup.procs         ← processes in the root cgroup
├── system.slice/        ← systemd-managed services
│   ├── docker.service/  ← the Docker daemon itself
│   └── docker-<id>.scope/  ← each container
│       ├── cgroup.procs    ← PIDs in this container
│       ├── cpu.max
│       ├── memory.max
│       └── pids.max
├── kubepods.slice/      ← Kubernetes pods (on a K8s node)
│   ├── guaranteed/
│   ├── burstable/
│   └── besteffort/
└── user.slice/          ← user sessions
```

---

## Checkpoint

1. What is `/sys/fs/cgroup/` and why is it a filesystem rather than a set of syscalls?
2. What does `cpu.max "50000 100000"` mean, in plain English?
3. How many bytes does `--memory 128m` translate to in `memory.max`?
4. What is the OOM killer and when does it fire? What exit code does it produce?
5. What does `pids.max` protect against?
6. What are the three Kubernetes QoS classes and how do they map to cgroup directories?
7. How do you manually add a process to a cgroup?
8. What is the difference between `memory.max` and `memory.swap.max`?
9. Where are container cgroups located on a kind/Kubernetes node?
10. What is the difference between `--cpus` (resource limits) and `--cpu-shares` (resource requests) in Docker?

➡ Next up: **OverlayFS** — now that we know how containers are isolated (namespaces) and resource-limited (cgroups), let's look at the filesystem layer: how Docker layers images and how OverlayFS gives each container its own writable view without copying gigabytes of data.
