# Container Security — What Stops a Container Escaping

> **Module 09 · Course 37** — A container is not a VM. The kernel is shared. What actually stops a rogue container from becoming root on the host? The answer is several layers: Linux capabilities, seccomp syscall filtering, AppArmor/SELinux policies, and user namespaces. This module explains each one, shows you how Docker uses them, and shows you what `--privileged` turns off.

---

## The Threat Model

A container shares the host kernel. If a container process finds a kernel vulnerability, namespaces and cgroups won't save you — the exploit runs at kernel level and all bets are off.

Short of kernel exploits, the defense layers are:
1. **User** — running as a non-root user inside the container
2. **Capabilities** — limiting which kernel privileges the process has
3. **seccomp** — blocking specific syscalls the process can make
4. **AppArmor/SELinux** — mandatory access control policies
5. **User namespaces** — mapping container root to unprivileged host UID
6. **Read-only filesystem** — preventing modification of the container's filesystem

You want as many of these as possible. This module shows you how.

---

## Linux Capabilities: Root Is Not a Single Thing

Traditional Linux had a binary model: root (UID 0) can do anything, non-root is limited. Modern Linux splits root's powers into ~40 fine-grained **capabilities**. A process can have some capabilities without being full root.

```bash
# See all capabilities
man capabilities | head -100

# Check capabilities of a running process
cat /proc/1/status | grep -i cap
# CapInh: 0000000000000000
# CapPrm: 000001ffffffffff   ← permitted set (what it can use)
# CapEff: 000001ffffffffff   ← effective set (currently active)
# CapBnd: 000001ffffffffff   ← bounding set (ceiling — can't add above this)

# More readable output with capsh
capsh --decode=000001ffffffffff
# 0x000001ffffffffff=cap_chown,cap_dac_override,...

# Inside a container
docker run --rm alpine capsh --print
```

---

## Key Capabilities

| Capability | What it allows | In Docker default? |
|------------|---------------|-------------------|
| `CAP_NET_ADMIN` | Configure interfaces, iptables, routing | **dropped** |
| `CAP_SYS_ADMIN` | Mount filesystems, namespace operations, `ptrace`, dozens of things | **dropped** |
| `CAP_SYS_PTRACE` | Use `ptrace()` — debug other processes | **dropped** |
| `CAP_SYS_MODULE` | Load/unload kernel modules | **dropped** |
| `CAP_SYS_RAWIO` | Access raw I/O ports, `/dev/mem` | **dropped** |
| `CAP_MKNOD` | Create device nodes | **dropped** |
| `CAP_NET_BIND_SERVICE` | Bind to ports < 1024 | kept |
| `CAP_CHOWN` | Change file ownership | kept |
| `CAP_SETUID` / `CAP_SETGID` | Change UID/GID | kept |
| `CAP_KILL` | Send signals to other processes | kept |
| `CAP_NET_RAW` | Raw socket access (ping, ARP spoofing) | kept* |

*Docker kept `NET_RAW` for years to allow `ping` to work. Recent versions may drop it.

Docker drops **14+ capabilities** by default compared to running a process directly on the host.

```bash
# Drop ALL capabilities, add back only what you need
docker run --rm \
  --cap-drop ALL \
  --cap-add NET_BIND_SERVICE \
  nginx:1.27-alpine capsh --print
# Current: = cap_net_bind_service+eip
# (only NET_BIND_SERVICE remains)
```

---

## seccomp: Blocking Syscalls

A process interacts with the kernel through **syscalls** (`read`, `write`, `clone`, `mount`, `ioctl`, etc.). seccomp (Secure Computing Mode) is a kernel feature that lets you install a filter that decides which syscalls are allowed.

Docker applies a **default seccomp profile** that blocks ~44 syscalls, including:
- `pivot_root` (change root filesystem)
- `clone` with `CLONE_NEWUSER` (create user namespaces from inside container)
- `mount` (mount filesystems)
- `unshare` (create new namespaces)
- `kexec_load` (load a new kernel)
- `add_key`, `request_key` (kernel key management)

```bash
# See if seccomp is active on a container
docker inspect <container> --format '{{.HostConfig.SecurityOpt}}'
# [seccomp:{"defaultAction":"SCMP_ACT_ERRNO",...}]

# Test: try to create a user namespace (blocked by seccomp)
docker run --rm alpine unshare --user echo "created user namespace"
# unshare: unshare(0x10000000): Operation not permitted
# (blocked by seccomp's CLONE_NEWUSER restriction)
```

**Custom seccomp profiles:**
```bash
# Download the default profile
curl -o default.json https://raw.githubusercontent.com/moby/moby/master/profiles/seccomp/default.json

# Use a custom profile
docker run --rm \
  --security-opt seccomp=default.json \
  nginx:1.27-alpine

# Disable seccomp entirely (don't do this in production)
docker run --rm \
  --security-opt seccomp=unconfined \
  nginx:1.27-alpine
```

---

## AppArmor

AppArmor is a Linux Security Module (LSM) that enforces **mandatory access control** policies based on file paths and operations.

Docker automatically uses the `docker-default` AppArmor profile on systems with AppArmor:
- Allows reading most of the filesystem
- Allows writing to `/proc` (limited), `/tmp`, app directories
- Blocks writing to `/proc/sysrq-trigger`, `/proc/kcore`, etc.
- Blocks mounting new filesystems
- Blocks modifying network routing rules

```bash
# Check if AppArmor is active
cat /proc/self/attr/current
# docker-default (enforce)

# See the profile
cat /etc/apparmor.d/docker-default  # may vary by distro

# Load a custom profile
apparmor_parser -r -W /path/to/profile
docker run --rm --security-opt apparmor=my-profile nginx:1.27-alpine
```

---

## User Namespace Remapping: Root �� Root

By default, UID 0 inside a Docker container IS UID 0 on the host. If a container somehow writes to a bind-mounted host directory as root, it writes as real root.

**User namespace remapping** changes this: UID 0 in the container maps to an unprivileged UID (e.g., 100000) on the host.

```bash
# Enable userns-remap in daemon config
# /etc/docker/daemon.json:
# { "userns-remap": "default" }
# Then restart: sudo systemctl restart docker

# With userns-remap enabled:
docker run --rm alpine id
# uid=0(root) gid=0(root)   ← container still sees itself as root

# But on the host:
docker run -d --name remap-test alpine sleep 3600
ps aux | grep "sleep 3600"
# 100000 ... sleep 3600   ← running as UID 100000 on the host, not root!
docker rm -f remap-test
```

Trade-offs of userns-remap:
- Volumes: files created by the container are owned by UID 100000 on the host
- Some features unavailable (host networking, some mounts)
- Performance: slightly slower due to UID translation

---

## `--privileged` — The Nuclear Option

`--privileged` disables almost all security mechanisms:
- Drops ALL capabilities restrictions (gets ALL capabilities)
- Disables seccomp
- Disables AppArmor
- Gains access to all host devices
- Can mount filesystems

```bash
# This is essentially root on the host — treat it as such
docker run --rm --privileged alpine sh

# From inside --privileged:
mount /dev/sda1 /mnt         # mount real host disks
fdisk -l                     # enumerate host disks
nsenter --mount=/proc/1/ns/mnt  # enter host mount namespace
# Now you have full host access
```

**Legitimate uses of --privileged:**
- Docker-in-Docker (DinD) in CI
- Containers that manage host network (Flannel, Cilium on old setups)
- Hardware access containers (GPIO, USB)

**Cargo-cult uses to audit and remove:**
- "It needed more permissions so I added --privileged"
- Jenkins/GitLab runners that don't actually need DinD

The alternative: grant specific capabilities and devices:
```bash
# Instead of --privileged for network management:
docker run --rm \
  --cap-add NET_ADMIN \
  --cap-add NET_RAW \
  alpine ip route

# Instead of --privileged for device access:
docker run --rm \
  --device /dev/sda:/dev/sda:r \
  alpine dd if=/dev/sda bs=1M count=1 | xxd | head
```

---

## no-new-privileges

The `no-new-privileges` security option prevents processes inside the container from gaining new privileges through `setuid` binaries or `sudo`.

```bash
docker run --rm \
  --security-opt no-new-privileges \
  nginx:1.27-alpine

# Effect: setuid binaries don't work
# A container running as UID 1000 cannot su to root even if /usr/bin/su is setuid
```

Always set this unless your app specifically needs setuid binaries (rare).

---

## The Full Hardened Container

Putting it all together — the most secure way to run a container:

```bash
docker run \
  --user 10001:10001 \               # non-root user
  --cap-drop ALL \                   # drop ALL capabilities
  --cap-add NET_BIND_SERVICE \       # add back only what's needed (optional)
  --security-opt no-new-privileges \ # block privilege escalation
  --security-opt seccomp=default \   # enforce default seccomp
  --read-only \                      # read-only root filesystem
  --tmpfs /tmp:size=50m \            # writable tmpfs only for /tmp
  --tmpfs /var/run:size=10m \        # and /var/run for pid files
  nginx:1.27-alpine
```

In Kubernetes, this translates to:

```yaml
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    seccompProfile:
      type: RuntimeDefault      # enforces the default seccomp profile
  containers:
    - name: app
      image: nginx:1.27-alpine
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
          add: ["NET_BIND_SERVICE"]  # only if needed
      volumeMounts:
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: tmp
      emptyDir:
        medium: Memory
        sizeLimit: 50Mi
```

---

## Scanning Images for CVEs

Security hardening in the Dockerfile and runtime is half the story. The other half is keeping dependencies patched:

```bash
# Scan an image with trivy (open source)
trivy image nginx:1.27-alpine
# Output: table of CVEs by severity (CRITICAL, HIGH, MEDIUM, LOW)
# Shows: CVE ID, affected package, installed version, fixed version

# Fail CI on HIGH+ with a fix available
trivy image --exit-code 1 --severity HIGH,CRITICAL nginx:1.27-alpine

# Scan filesystem (not just image)
trivy fs .
```

---

## Checkpoint

1. What are Linux capabilities and why do they matter for container security?
2. Which capability allows mounting filesystems? Which allows configuring iptables?
3. What does seccomp do? Name three syscalls Docker's default profile blocks.
4. Why is `--cap-drop ALL --cap-add NET_BIND_SERVICE` safer than just not adding `--privileged`?
5. What does `--security-opt no-new-privileges` prevent?
6. What does `--privileged` actually turn off? Name three security mechanisms.
7. What is the difference between user namespace remapping and running as a non-root USER in the Dockerfile?
8. What does `readOnlyRootFilesystem: true` prevent an attacker from doing?
9. How does AppArmor differ from seccomp?
10. In Kubernetes, what field enforces the default seccomp profile on a pod?

➡ Next up: **Build a Container Runtime from Scratch** — now that you understand all the pieces (namespaces, cgroups, overlayfs, capabilities, seccomp), let's assemble them manually and create a container without Docker.
