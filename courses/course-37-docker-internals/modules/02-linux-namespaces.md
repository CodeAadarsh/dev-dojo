# Linux Namespaces — The Walls That Make a Container

> **Module 02 · Course 37** — A container isn't magic. It's a regular Linux process with a restricted view of the world. The kernel uses **namespaces** to give it that restricted view — each namespace hides a different part of the system. This module shows you all eight, what each one isolates, and how to poke at them from both sides.

---

## What Is a Namespace?

Think of a namespace as giving a process its own **window** onto a part of the kernel. The host has a global filesystem, a global process table, a global network stack. A namespace carves out a private copy of one of those things. Processes inside the namespace see their version; they can't see outside.

```
  HOST VIEW                          CONTAINER VIEW
  ─────────────────────────          ─────────────────────────
  PID namespace:                     PID namespace:
    PID 1  → systemd                   PID 1  → your app   ← same process,
    PID 234 → dockerd                  PID 2  → worker        different PID number
    PID 891 → your app ──────────────────────────────────►

  Network namespace:                 Network namespace:
    eth0  → 192.168.1.5                eth0  → 172.17.0.2  ← separate interface
    lo    → 127.0.0.1                  lo    → 127.0.0.1

  Mount namespace:                   Mount namespace:
    /                → host disk        /            → container rootfs
    /home/aadarsh    → real home        /home        → (empty or not mounted)
    /var/lib/docker  → docker data      /app         → your app files
```

The process with PID 891 on the host is PID 1 inside the container. Same process, different view — the kernel just maps PIDs differently per namespace.

---

## The Eight Namespace Types

Linux currently has eight namespace types. Docker uses most of them.

| Namespace | Flag | Isolates |
|-----------|------|---------|
| **mnt** | `CLONE_NEWNS` | Filesystem mounts — each container gets its own mount table |
| **pid** | `CLONE_NEWPID` | Process IDs — container PIDs start at 1, unaware of host PIDs |
| **net** | `CLONE_NEWNET` | Network interfaces, routes, iptables rules, ports |
| **ipc** | `CLONE_NEWIPC` | POSIX message queues, System V IPC semaphores and shared memory |
| **uts** | `CLONE_NEWUTS` | Hostname and NIS domain name |
| **user** | `CLONE_NEWUSER` | UID/GID mappings — root (0) in container maps to non-root on host |
| **cgroup** | `CLONE_NEWCGROUP` | The cgroup root — container sees its own subtree as `/` |
| **time** | `CLONE_NEWTIME` | System clock offsets (Linux 5.6+, rarely used) |

---

## mnt — Mount Namespace

The mount namespace is what lets a container have `/` point to a Docker image instead of the real root filesystem.

When Docker creates a container, it:
1. Assembles the OverlayFS rootfs from the image layers
2. Creates a new mount namespace
3. Mounts the rootfs as `/` in that namespace
4. Mounts `/proc`, `/sys`, `/dev` inside it

Changes to the mount table (new mounts, unmounts) in one namespace don't affect other namespaces. This is the "M" in `CLONE_NEWNS` — it was actually the **first** namespace type Linux added (kernel 2.4.19, 2002).

```bash
# Host has many mounts
cat /proc/mounts | wc -l  # maybe 30-40 entries

# Container has its own minimal mount table
docker run --rm alpine cat /proc/mounts
# output: overlay, proc, tmpfs, devtmpfs — just the essentials
```

---

## pid — PID Namespace

The PID namespace gives a process tree its own numbering starting at 1.

The **first process** in a PID namespace becomes PID 1. This matters because:
- PID 1 is special: when it exits, the kernel kills all other processes in that namespace
- PID 1 is the parent of orphaned processes (zombie reaping)
- Many init systems (`systemd`, `tini`) expect to run as PID 1

```bash
# Start a container and check its PID from both sides
docker run -d --name pidtest nginx:1.27-alpine
# From the container's perspective — sees itself as PID 1
docker exec pidtest cat /proc/1/comm
# output: nginx

# From the host — the same process has a different PID
docker inspect pidtest --format '{{.State.Pid}}'
# output: 12345 (or whatever the actual host PID is)
ps -p 12345 -o comm=
# output: nginx
```

```
  host PID namespace              container PID namespace
  ───────────────────             ───────────────────────
  PID 1   systemd                 PID 1   nginx (master)
  PID 2   kthreadd                PID 2   nginx (worker)
  ...
  PID 12345  nginx ──────────────►
  PID 12346  nginx ──────────────► PID 2
```

---

## net — Network Namespace

The network namespace is a complete, isolated copy of the network stack:
- Network interfaces (the container gets a virtual `eth0`, the host has the real one)
- Routing tables
- iptables rules
- Port numbers (a process in one namespace can bind :80 without conflicting with another namespace binding :80)

```bash
# See that the container has its own interfaces
docker run --rm alpine ip addr
# 1: lo: <LOOPBACK> ...
# 2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> ... 172.17.0.2/16

# The host has completely different interfaces
ip addr
# 1: lo ...
# 2: eth0 ...  192.168.1.5/24
# 3: docker0 ...  172.17.0.1/16
# 4: veth123abc ...  (the other end of the container's eth0)
```

---

## ipc — IPC Namespace

IPC (Inter-Process Communication) namespace isolates:
- **POSIX message queues** (`mq_open`, `/dev/mqueue`)
- **System V IPC**: semaphores (`semget`), shared memory (`shmget`), message queues (`msgget`)

Processes in the same Pod share an IPC namespace (via the pause container), which is why you can use shared memory between containers in the same Pod. Containers in different Pods cannot.

---

## uts — UTS Namespace

UTS stands for "UNIX Time-sharing System" — a historical name. This namespace isolates the **hostname** and **NIS domain name**.

That's why `hostname` inside a container returns the container ID (or whatever you set with `--hostname`), while the host has its own hostname.

```bash
# Default: container hostname = container ID
docker run --rm alpine hostname
# 7f3a2b1c9d4e

# Custom hostname
docker run --rm --hostname my-app alpine hostname
# my-app
```

---

## user — User Namespace

The user namespace is the most powerful (and most complex). It maps **UIDs and GIDs** between the namespace and the host.

The key insight: **UID 0 (root) inside a user namespace maps to a non-root UID on the host**.

```
  Container (user namespace)    Host
  ──────────────────────────    ──────────────────────
  UID 0 (root)          ──────► UID 100000 (unprivileged)
  UID 1000 (appuser)    ──────► UID 101000
```

Why this matters: if a container breaks out, it's running as an unprivileged user on the host. This is the basis of **rootless Docker** (`dockerd --userns-remap=default`).

```bash
# With userns-remap, root in container is non-root on host
docker run --rm alpine id
# uid=0(root) gid=0(root)

# But on the host, that process runs as UID 100000
ps aux | grep nginx  # shows UID 100000, not 0
```

**Note:** Docker doesn't enable user namespaces by default for most operations (it has tradeoffs with volume permissions). Enable explicitly with `--userns-remap`.

---

## cgroup — cgroup Namespace

The cgroup namespace isolates the **cgroup hierarchy view**. A containerized process sees its cgroup subtree as `/` in `/sys/fs/cgroup/` — it can't see the host's full hierarchy or other containers' cgroups.

---

## Listing and Inspecting Namespaces

```bash
# List all namespaces on the host
lsns
# Output (abbreviated):
#        NS TYPE   NPROCS   PID USER   COMMAND
# 4026531834 time      123     1 root   /sbin/init
# 4026531835 cgroup    123     1 root   /sbin/init
# 4026531836 user       123     1 root   /sbin/init
# 4026532008 mnt          2 12345 root   nginx: master

# See a process's namespaces (the symlinks point to the namespace object)
ls -la /proc/12345/ns/
# lrwxrwxrwx 1 root root 0 Nov 25 10:00 cgroup -> cgroup:[4026531835]
# lrwxrwxrwx 1 root root 0 Nov 25 10:00 ipc -> ipc:[4026532009]
# lrwxrwxrwx 1 root root 0 Nov 25 10:00 mnt -> mnt:[4026532008]
# lrwxrwxrwx 1 root root 0 Nov 25 10:00 net -> net:[4026532010]
# lrwxrwxrwx 1 root root 0 Nov 25 10:00 pid -> pid:[4026532011]
# lrwxrwxrwx 1 root root 0 Nov 25 10:00 user -> user:[4026531836]
# lrwxrwxrwx 1 root root 0 Nov 25 10:00 uts -> uts:[4026532012]
```

Two processes sharing a namespace inode number (e.g., both have `net:[4026532010]`) are in the **same** network namespace.

---

## Entering a Container's Namespaces Without `docker exec`

`nsenter` lets you enter specific namespaces of a running process. This is what `docker exec` does under the hood.

```bash
# Get the container's host PID
CPID=$(docker inspect my-container --format '{{.State.Pid}}')
echo "Container PID on host: $CPID"

# Enter just the network namespace and run a command
sudo nsenter -t $CPID --net ip addr
# Shows the container's network interfaces without being "inside" the container

# Enter all namespaces (equivalent to docker exec)
sudo nsenter -t $CPID --mount --uts --ipc --net --pid -- /bin/sh

# Check you're really inside (hostname will be the container's)
hostname
# 7f3a2b1c9d4e
```

This is useful for debugging distroless containers — the container has no shell, but `nsenter` from the host can run any tool.

---

## Full Worked Example: Namespace Exploration

Let's start a container and explore its namespaces step by step:

```bash
# Start a background container
docker run -d --name ns-test nginx:1.27-alpine

# 1. Get the host PID
HOST_PID=$(docker inspect ns-test --format '{{.State.Pid}}')
echo "Host PID: $HOST_PID"

# 2. Compare namespace IDs — host process vs container process
echo "--- Host init namespaces ---"
ls -la /proc/1/ns/
echo ""
echo "--- Container process namespaces ---"
ls -la /proc/$HOST_PID/ns/

# 3. The ones that differ: mnt, pid, net, uts, ipc
#    The ones that are shared: user, cgroup (if user ns not enabled)

# 4. Enter the net namespace and see the container's network
sudo nsenter -t $HOST_PID --net ip route
# 10.0.0.0/8 dev eth0 — container routing, not host routing

# 5. Enter the mount namespace and see the container's filesystem
sudo nsenter -t $HOST_PID --mount ls /
# bin  dev  etc  home  lib  media  mnt  opt  proc  root  run  ...
# This is the Alpine rootfs, not your host /

# 6. See the container's hostname from outside
sudo nsenter -t $HOST_PID --uts hostname
# <container-id>

# 7. See all container processes from the host's view
ps --ppid $HOST_PID  # shows worker processes

# Cleanup
docker rm -f ns-test
```

---

## How Docker Creates Namespaces: The clone() Call

Docker calls `clone(2)` (via runc) with namespace flags OR uses `unshare(2)` to detach from an existing namespace. The flags are:

```c
// Simplified — what runc does for a standard container
clone(container_main,
      CLONE_NEWPID   |   // new PID namespace
      CLONE_NEWNET   |   // new network namespace
      CLONE_NEWNS    |   // new mount namespace
      CLONE_NEWIPC   |   // new IPC namespace
      CLONE_NEWUTS,      // new UTS (hostname) namespace
      args);
```

You can try this yourself with the `unshare` command (the userspace wrapper around `unshare(2)`):

```bash
# Create a new UTS namespace just to change hostname
sudo unshare --uts /bin/bash
hostname test-namespace
hostname  # output: test-namespace
exit

hostname  # host unchanged: original-hostname
```

---

## Namespaces Are Reference-Counted

A namespace exists as long as at least one process is in it **OR** there's a file descriptor open to it (`/proc/<pid>/ns/<type>`). You can "pin" a namespace by bind-mounting its `/proc/*/ns/*` path:

```bash
# Pin a network namespace so it survives after all processes leave
sudo touch /run/netns/my-net
sudo mount --bind /proc/$CPID/ns/net /run/netns/my-net

# Now you can enter it even after $CPID exits
sudo ip netns exec my-net ip addr  # ip netns uses bind-mounted namespaces
```

This is how `ip netns` works — it manages named network namespaces by bind-mounting them in `/run/netns/`.

---

## Checkpoint

1. Name all eight Linux namespace types and what each one isolates.
2. What is the significance of PID 1 in a PID namespace?
3. Why does `docker exec` put you in the container's namespaces? What syscall/command does it use under the hood?
4. If two processes have the same inode number for `net:[xxxxxxx]`, what does that mean?
5. What does `nsenter -t <pid> --net ip addr` show you, and when would you use it instead of `docker exec`?
6. Explain what `clone(CLONE_NEWPID)` does differently from `fork()`.
7. What is a user namespace and why does it make container escapes less dangerous?
8. How can you pin a namespace so it survives even after all processes inside it exit?
9. Which namespaces does Docker NOT create by default for most containers (and why)?
10. If a Pod has three containers, which namespaces do they share and why?

➡ Next up: **cgroups** — now that containers are isolated from each other (namespaces), we need to limit how much of the host's resources they can consume.
