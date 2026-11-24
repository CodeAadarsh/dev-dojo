# Bare Metal Container

Forget Docker. Forget containerd. Forget runc.

A rootfs has been prepared for you at `/tmp/dojo-rootfs/`. Somewhere inside, at `/secret/flag.txt`, is the flag. But here is the catch: **you cannot read it directly from the host**. The flag exists inside the rootfs, and you must enter it properly by creating your own container using only Linux kernel primitives.

No `docker` command. No `kubectl`. Just you, the kernel, and the right syscalls.

---

## Why this matters

Docker, containerd, and runc are all wrappers around the same ~5 Linux features. When you strip away all the tooling, a container is:

1. **Namespaces** — a process's restricted view of the system (its own PID list, network, filesystem root, etc.)
2. **cgroups** — resource limits enforced by the kernel
3. **A rootfs** — a directory tree that becomes the container's `/`
4. **pivot_root or chroot** — the syscall that makes the new directory tree the new `/`

runc does exactly this, plus OCI hooks and some JSON parsing. That's it.

Understanding this lets you debug strange container behavior at the kernel level, write your own lightweight runtimes, and understand exactly what an "escape" means.

---

## Mission

A rootfs is at `/tmp/dojo-rootfs/`. The flag is inside at `/secret/flag.txt`.

Create a "container" using only Linux primitives so that the rootfs appears as `/` to your process, then read the flag.

**You may use:**

- `unshare` — creates new namespaces
- `chroot` / `pivot_root` — changes the root directory
- `mount` — mounts filesystems
- Standard POSIX shell commands

**You may NOT use:**

- `docker`, `nerdctl`, `podman`, or any container runtime
- `kubectl`

> **Note:** This challenge runs on the host, not inside Kubernetes. Run the setup script from the kube-dojo root, then work on the host terminal.

Run the setup:

```bash
bash courses/course-37-docker-internals/challenges/12-bare-metal-container/setup.sh
```
