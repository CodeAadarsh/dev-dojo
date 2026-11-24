# Solution: Namespace Spelunker

## Step 1 — Find the container's host PID

Every container process has a PID on the host — it's just a process with restricted views. Docker knows it:

```bash
docker inspect dojo-spelunker --format '{{.State.Pid}}'
# Example output: 12345
CPID=$(docker inspect dojo-spelunker --format '{{.State.Pid}}')
echo "Container PID: $CPID"
```

## Step 2 — Verify the namespace from the host

Before entering, see the difference between your namespace and the container's:

```bash
# Your shell's mount namespace
ls -la /proc/$$/ns/mnt
# lrwxrwxrwx 1 root root 0 ... mnt -> mnt:[4026531840]

# Container's mount namespace (different inode = different namespace)
ls -la /proc/$CPID/ns/mnt
# lrwxrwxrwx 1 root root 0 ... mnt -> mnt:[4026532xxx]  <-- different!
```

Different inode numbers mean different namespace — the container has its own private filesystem view.

## Step 3 — Enter the mount namespace and read the flag

```bash
# Read the flag directly
sudo nsenter -t $CPID --mount cat /secret/flag.txt

# Or enter interactively
sudo nsenter -t $CPID --mount sh
# now you're in the container's filesystem
ls /secret/
cat /secret/flag.txt
exit
```

**Flag:** `KUBE{namespaces_isolate_kernel_views}`

## What nsenter Actually Does

`nsenter` calls the `setns(2)` syscall. This syscall takes a file descriptor pointing to a namespace (the files in `/proc/<pid>/ns/`) and joins the calling process to that namespace. After `setns`, the process sees the same view of the world as the target.

```
nsenter -t 12345 --mount
  → opens /proc/12345/ns/mnt  (a file descriptor to the mount namespace)
  → calls setns(fd, CLONE_NEWNS)
  → your shell now shares the container's mount namespace
  → cat /secret/flag.txt reads from the container's filesystem
```

## The Security Implication

This is why `--privileged` containers or containers with `CAP_SYS_ADMIN` are dangerous: a process inside such a container can call `setns()` to enter the host's namespaces, escaping the container entirely. `nsenter` on the host is a legitimate ops tool; the same technique from inside a container is a container escape.

## Deeper: See All Namespaces

```bash
# List all namespaces on the host
lsns

# See which namespaces the container process is in
ls -la /proc/$CPID/ns/
# mnt  pid  net  ipc  uts  user  cgroup — all different from host
```
