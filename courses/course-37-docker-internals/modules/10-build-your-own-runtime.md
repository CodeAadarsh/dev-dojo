# Build a Container Runtime from Scratch

> **Module 10 · Course 37** — This is the most hands-on module in the course. We're going to create a running "container" using nothing but Linux kernel primitives — no Docker, no containerd, no runc. Just bash, `unshare`, `pivot_root`, and writes to `/sys/fs/cgroup`. By the end, you'll understand exactly what runc does on every `docker run`, and you'll never look at a container the same way again.

---

## What We're Building

By the end of this module, we'll have:
- A process running in isolated PID, mount, network, and UTS namespaces
- Its own root filesystem (from an Alpine image)
- CPU and memory limits enforced by the kernel via cgroups
- A hostname different from the host

No Docker daemon involved. We're the runtime.

```
Our "container"                   Real Docker container
─────────────────                 ─────────────────────
unshare (namespaces)        ≈     runc + containerd-shim
pivot_root (rootfs)         ≈     OverlayFS mount + pivot_root
write to /sys/fs/cgroup     ≈     cgroup setup by runc
bash PID 1                  ≈     your app as PID 1
```

---

## Prerequisites

You need:
- Linux (not macOS — this uses Linux kernel features)
- Root access or `sudo`
- Docker installed (just to get a rootfs tarball — ironic)

> On macOS with Docker Desktop: Docker runs inside a Linux VM. You can SSH into it with `docker run --privileged --pid=host --net=host -it --rm alpine nsenter -t 1 -m -u -n -i sh` and do the exercises there.

---

## Step 1: Get a Root Filesystem

We need a Linux filesystem to use as our container's root. The easiest way is to export one from an existing Docker image:

```bash
# Create a directory for our container's rootfs
mkdir -p /tmp/my-container/rootfs

# Export Alpine's filesystem (without running it)
docker export $(docker create alpine:3.20) | tar -xC /tmp/my-container/rootfs

# Verify: looks like a Linux filesystem
ls /tmp/my-container/rootfs
# bin  dev  etc  home  lib  media  mnt  opt  proc  root  run  srv  sys  tmp  usr  var

# This is Alpine's complete filesystem — no kernel, just userland
ls /tmp/my-container/rootfs/bin
# ash  cat  cp  date  echo  grep  ls  mkdir  ps  sh  ...
```

What we have is a **rootfs**: a directory tree that looks like a Linux root partition. No running processes, no kernel — just files. This is what Docker stores as image layers, assembled by OverlayFS. We're using a flat export for simplicity.

---

## Step 2: Create Namespaces with unshare

`unshare` is the userspace tool that calls the `unshare(2)` syscall to create new namespaces. When you run `unshare --pid /bin/bash`, that bash shell runs in a new PID namespace.

```bash
# Create new namespaces and drop into a shell inside them
# We'll set up the rootfs manually in the next step
sudo unshare \
  --fork \             # fork before exec (required for PID namespace)
  --pid \              # new PID namespace
  --mount \            # new mount namespace (our mounts stay private)
  --uts \              # new UTS (hostname) namespace
  --net \              # new network namespace
  /bin/bash

# Verify we're in a new namespace
echo "My hostname: $(hostname)"    # will show the HOST's hostname still
echo "My PID: $$"                  # will be a small number (like 2 or 3)
ps aux                             # only shows processes in this namespace

# Exit for now — we'll add rootfs setup next
exit
```

**Why --fork?** A new PID namespace requires the first process to be PID 1. `unshare` itself is PID 1 of the new namespace before exec. `--fork` makes unshare fork a child, making the child PID 1 in the new namespace, while unshare waits as PID 1 in the parent namespace. This allows proper PID 1 behavior.

---

## Step 3: Set Up the Root Filesystem

`chroot` changes the root directory. `pivot_root` does it properly — it's what runc uses. The difference:
- `chroot`: changes root but old root is still accessible via `..` escape
- `pivot_root`: atomically swaps root and old-root, then you can unmount old root cleanly

We'll use pivot_root (the proper way):

```bash
# Full setup script — run as root
sudo bash << 'OUTER'
# Create namespaces
unshare --fork --pid --mount --uts --net /bin/bash << 'INNER'
set -e

ROOTFS=/tmp/my-container/rootfs

# 1. pivot_root requires the new root to be a mount point
#    (bind-mount it onto itself to make it a mount point)
mount --bind $ROOTFS $ROOTFS

# 2. Create a directory inside rootfs for the old root
mkdir -p $ROOTFS/old-root

# 3. Pivot: our rootfs becomes /, old host root goes to /old-root
cd $ROOTFS
pivot_root . old-root

# 4. We're now inside the Alpine rootfs!
#    Fix PATH for Alpine's bin locations
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 5. Mount essential filesystems
mount -t proc proc /proc           # process information
mount -t sysfs sysfs /sys          # kernel/driver info
mount -t devtmpfs devtmpfs /dev    # device nodes
mount -t tmpfs tmpfs /tmp          # writable /tmp

# 6. Unmount old root (lazy unmount in case anything is still using it)
umount -l /old-root
rmdir /old-root

# 7. Set hostname
hostname my-container

# 8. Prove isolation
echo ""
echo "=== We are inside our 'container' ==="
echo "Hostname: $(hostname)"
echo "Root filesystem: $(ls /)"
echo "Process list:"
ps aux
echo ""
echo "Network interfaces (isolated):"
ip addr
echo ""
echo "We cannot see the host's processes!"

# Stay here for a moment
exec /bin/sh
INNER
OUTER
```

---

## Step 4: The All-in-One Container Script

Here's a complete, clean script that creates a container in ~40 lines:

```bash
#!/usr/bin/env bash
# container.sh — create a container from scratch
# Usage: sudo bash container.sh
set -euo pipefail

ROOTFS=/tmp/my-container/rootfs
CONTAINER_NAME="${1:-my-container}"

# Ensure rootfs exists
if [ ! -d "$ROOTFS/bin" ]; then
    echo "Setting up rootfs from alpine:3.20..."
    mkdir -p "$ROOTFS"
    docker export $(docker create alpine:3.20) | tar -xC "$ROOTFS"
fi

echo "Starting container: $CONTAINER_NAME"

# This script runs INSIDE the new namespaces
INNER_SCRIPT=$(cat << 'EOF'
set -e
ROOTFS=/tmp/my-container/rootfs
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

mount --bind "$ROOTFS" "$ROOTFS"
mkdir -p "$ROOTFS/old-root" "$ROOTFS/proc" "$ROOTFS/sys" "$ROOTFS/dev" "$ROOTFS/tmp"

cd "$ROOTFS"
pivot_root . old-root

mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
mount -t tmpfs tmpfs /tmp

umount -l /old-root
rmdir /old-root

hostname "$CONTAINER_NAME"
exec /bin/sh
EOF
)

# Launch with new namespaces, running the inner script
exec unshare \
    --fork \
    --pid \
    --mount \
    --uts \
    --net \
    /bin/bash -c "$INNER_SCRIPT"
```

```bash
# Run it
sudo bash container.sh my-first-container

# Inside the container:
hostname                   # my-first-container
ps aux                     # only our processes
ip addr                    # only loopback (network namespace is empty)
ls /                       # alpine filesystem
cat /etc/os-release        # Alpine Linux
```

---

## Step 5: Add cgroup Limits from the Host

While the container is running, open **another terminal** and apply resource limits from the host:

```bash
# Find the PID of our unshare process (from the host's view)
CPID=$(pgrep -f "unshare --fork")
echo "Container root PID on host: $CPID"

# Create a cgroup for our container
sudo mkdir -p /sys/fs/cgroup/my-container

# Add our container's process tree to this cgroup
echo "$CPID" | sudo tee /sys/fs/cgroup/my-container/cgroup.procs

# Apply limits
echo "50000 100000" | sudo tee /sys/fs/cgroup/my-container/cpu.max     # 50% CPU
echo "67108864" | sudo tee /sys/fs/cgroup/my-container/memory.max      # 64MB RAM
echo "50" | sudo tee /sys/fs/cgroup/my-container/pids.max              # max 50 processes

# Verify: from inside the container, try to fork more than 50 processes
# (back in container terminal)
for i in $(seq 1 100); do sleep 100 & done
# bash: fork: retry: No child processes — hits pids.max at ~50!

# Check live usage from host
cat /sys/fs/cgroup/my-container/memory.current
cat /sys/fs/cgroup/my-container/cpu.stat

# Cleanup the cgroup when done
sudo rmdir /sys/fs/cgroup/my-container
```

---

## Step 6: What We Built vs What runc Does

Our script does the core of what runc does. Here's what we skipped:

| Feature | Our script | runc |
|---------|-----------|------|
| Namespaces | ✓ unshare | ✓ clone(2) flags |
| pivot_root | ✓ | ✓ |
| /proc /sys /dev mounts | ✓ | ✓ |
| cgroups | ✓ manual | ✓ automatic per OCI spec |
| Capabilities | ✗ | ✓ drops all, adds back per spec |
| seccomp filter | ✗ | ✓ default profile applied |
| AppArmor | ✗ | ✓ docker-default profile |
| /dev/pts (terminal) | ✗ | ✓ devpts mount |
| /dev device nodes | partial | ✓ full /dev setup |
| OCI spec (config.json) | ✗ | ✓ reads config.json |
| Lifecycle hooks | ✗ | ✓ prestart, start, poststart |
| State machine | ✗ | ✓ created/running/stopped |
| Shim protocol | ✗ | ✓ via containerd-shim |

The core isolation mechanism (namespaces + cgroups + pivot_root) is the same. Everything else runc adds is polish, security hardening, and integration with the containerd ecosystem.

---

## Bonus: Network Setup

Our container has an isolated network namespace but no connectivity. Here's how to give it network access (this is roughly what Docker does for the bridge network):

```bash
# From the host (while container is running):
CPID=$(pgrep -f "unshare --fork")

# Create a veth pair
sudo ip link add veth0-host type veth peer name veth0-container

# Move one end into the container's network namespace
sudo ip link set veth0-container netns $CPID

# Configure the host end
sudo ip addr add 10.100.0.1/24 dev veth0-host
sudo ip link set veth0-host up

# Configure the container end (using nsenter to run commands inside the net namespace)
sudo nsenter -t $CPID --net bash << 'NETCFG'
ip addr add 10.100.0.2/24 dev veth0-container
ip link set veth0-container up
ip link set lo up
ip route add default via 10.100.0.1
NETCFG

# From inside the container, ping the host:
# ping 10.100.0.1   ← works!

# For internet access, add NAT on the host:
sudo iptables -t nat -A POSTROUTING -s 10.100.0.0/24 -j MASQUERADE
sudo sysctl -w net.ipv4.ip_forward=1
# Now the container can reach the internet via the host
```

This is exactly what Docker does when it creates a veth pair and attaches it to `docker0`. We just did it manually.

---

## Checkpoint

1. What is `unshare --fork` and why is `--fork` required for PID namespaces?
2. What is the difference between `chroot` and `pivot_root`? Why does runc use `pivot_root`?
3. Why do we need `mount --bind $ROOTFS $ROOTFS` before calling `pivot_root`?
4. After `pivot_root`, why do we need to `umount -l /old-root`?
5. Why can't we set up cgroups from inside the container script?
6. What mounts are needed inside every container (`/proc`, `/sys`, `/dev`) and why?
7. Name three things runc adds that our script doesn't implement.
8. How does `veth` pair creation give a container network access?
9. What two host-side commands are needed after creating veth pairs to allow internet access from the container?
10. If you wanted to add seccomp to our container script, what tool/syscall would you use?

➡ Final module: **Run Your Own Docker Registry** — you've built the container, now build the place to store images. We'll implement the OCI Distribution Spec and run a registry with authentication that others can push to.
