# Volumes and Storage — Where Data Lives

> **Module 08 · Course 37** — A container's filesystem is ephemeral. The writable layer (upperdir from OverlayFS) is deleted the moment `docker rm` runs. If your app wrote a file there, it's gone. This module explains the three types of persistent storage Docker supports, where each one lives on the host, and how to choose between them.

---

## The Problem: Container Layers Are Ephemeral

From Module 04, you know that containers have a writable `upperdir`. When a container writes a file, it goes into that upperdir. When the container is removed, the upperdir is deleted.

```bash
# Demonstrate data loss
docker run --name data-test nginx:1.27-alpine sh -c 'echo "important data" > /data.txt'
docker start data-test  # re-run doesn't help — a new container
docker rm data-test
docker run --name data-test2 nginx:1.27-alpine cat /data.txt
# cat: can't open '/data.txt': No such file or directory
```

The app needs to persist data **outside** the container layer.

---

## The Three Mount Types

```
Container view:            What's actually happening:
─────────────              ─────────────────────────────────────────────────
/app/data/   ◄──────────── Named volume: /var/lib/docker/volumes/myapp-data/_data/
/app/src/    ◄──────────── Bind mount: /Users/you/code/myapp/ (host path)
/tmp/cache/  ◄──────────── tmpfs: in RAM only (gone on container stop)
/app/server  ◄──────────── Container layer (OverlayFS upperdir, ephemeral)
```

---

## Named Volumes

A named volume is Docker-managed storage. Docker creates a directory at `/var/lib/docker/volumes/<name>/_data` and mounts it into the container. The volume lives independently of any container — you can remove and recreate containers without losing data.

```bash
# Create a named volume
docker volume create myapp-data

# Use it
docker run -d \
  --name app \
  --volume myapp-data:/app/data \
  nginx:1.27-alpine

# Write data
docker exec app sh -c 'echo "persisted" > /app/data/file.txt'

# Remove the container
docker rm -f app

# Volume still exists!
docker volume ls
# DRIVER    VOLUME NAME
# local     myapp-data

# New container, same data
docker run --rm \
  --volume myapp-data:/app/data \
  nginx:1.27-alpine cat /app/data/file.txt
# persisted

# See where it lives on the host
docker volume inspect myapp-data
# "Mountpoint": "/var/lib/docker/volumes/myapp-data/_data"
ls /var/lib/docker/volumes/myapp-data/_data/
# file.txt
```

**Named volumes are the recommended way to persist data in production containers.** They're managed by Docker, easy to back up (`docker run --volumes-from`), and work across container recreations.

---

## Bind Mounts

A bind mount maps a **specific host path** directly into the container. Changes inside the container are immediately visible on the host, and vice versa.

```bash
# Mount the current directory into the container
docker run --rm \
  --volume $(pwd):/workspace \
  --workdir /workspace \
  node:20-slim \
  node server.js

# Or use --mount (more explicit syntax)
docker run --rm \
  --mount type=bind,source=$(pwd),target=/workspace \
  --workdir /workspace \
  node:20-slim \
  node server.js
```

**Use bind mounts for:**
- Local development (live reload — container sees your edits instantly)
- Injecting config files (`--volume /etc/app.conf:/app/config.conf:ro`)
- Accessing host sockets (`--volume /var/run/docker.sock:/var/run/docker.sock`)

**Avoid in production because:**
- Path must exist on the host — breaks portability (CI, staging, prod have different paths)
- Container has full read/write access to the host directory — security risk
- No lifecycle management (can't do `docker volume rm` to clean up)

---

## tmpfs Mounts

A `tmpfs` mount lives in the host's RAM. It's the fastest storage option and completely disappears when the container stops.

```bash
docker run --rm \
  --tmpfs /tmp:size=100m,uid=1000 \
  nginx:1.27-alpine df -h /tmp
# Filesystem      Size  Used Avail Use% Mounted on
# tmpfs           100M     0  100M   0% /tmp
```

**Use tmpfs for:**
- Temporary files that don't need to survive restarts
- Sensitive data like credentials/session tokens that shouldn't touch disk
- Performance-critical scratch space

**Combined with `--read-only` for security:**
```bash
# Read-only root filesystem + writable tmpfs for /tmp and /var/run
docker run --rm \
  --read-only \
  --tmpfs /tmp:size=50m \
  --tmpfs /var/run:size=10m \
  nginx:1.27-alpine nginx -g 'daemon off;'
```

This is a security best practice: container can't write anywhere except explicitly allowed paths.

---

## Volume Mount Precedence (The Gotcha)

When a volume is mounted at a path that the image already has content at, the **volume wins** and the image content is hidden.

```bash
# nginx has /usr/share/nginx/html/ with index.html
# If you mount a volume there, the image's index.html disappears:
docker run --rm \
  --volume empty-vol:/usr/share/nginx/html \
  nginx:1.27-alpine ls /usr/share/nginx/html
# (empty — the volume shadows the image content)
```

**Exception:** When Docker creates a **new** named volume, it **copies the image content** into the volume first. But on subsequent runs, the volume's content is used (which may be stale compared to a new image version).

```bash
# First run: volume is populated from image
docker volume create html-vol
docker run --rm --volume html-vol:/usr/share/nginx/html nginx:1.27-alpine ls /usr/share/nginx/html
# 50x.html  index.html   ← copied from image on volume creation

# If you update the image (new tag), the volume still has old content
# This is why you sometimes need to delete and recreate volumes on image upgrades
```

---

## --volume vs --mount Syntax

Both do the same thing; `--mount` is more explicit and readable:

```bash
# --volume (shorthand, legacy)
-v /host/path:/container/path          # bind mount
-v myvolume:/container/path            # named volume
-v /container/path                     # anonymous volume (Docker-generated name)

# --mount (explicit, recommended)
--mount type=bind,source=/host/path,target=/container/path
--mount type=volume,source=myvolume,target=/container/path
--mount type=tmpfs,target=/container/path,tmpfs-size=50m
```

`--mount` catches mistakes: misspelling a volume name silently creates a new anonymous volume with `--volume`, but `--mount` raises an error if the named volume doesn't exist (without `--volume`, which creates it).

---

## Disk Usage and Cleanup

```bash
# See disk usage breakdown
docker system df
# TYPE             TOTAL    ACTIVE   SIZE     RECLAIMABLE
# Images           12       4        3.21GB   2.81GB
# Containers       6        3        145.1kB  72.5kB
# Local Volumes    8        3        1.2GB    800MB
# Build Cache      0        0        0B       0B

# Detailed volume usage
docker system df -v | grep -A20 "Local Volumes"

# Clean up unused volumes (NOT actively mounted by a container)
docker volume prune
# WARNING! This will remove anonymous local volumes not used by at least one container.

# Clean up everything unused (containers, images, volumes, networks, build cache)
docker system prune -a --volumes
# WARNING: removes everything not currently in use!
```

---

## In Kubernetes: Volumes, PVCs, and emptyDir

The Docker volume concept maps to Kubernetes volumes, but with more options:

```yaml
spec:
  containers:
    - name: app
      image: myapp:1.0
      volumeMounts:
        - name: data              # bind this volume to the container
          mountPath: /app/data
        - name: tmp               # tmpfs in K8s
          mountPath: /tmp
  volumes:
    - name: data
      persistentVolumeClaim:      # backed by a PersistentVolume
        claimName: myapp-pvc
    - name: tmp
      emptyDir:                   # like Docker tmpfs (dies with Pod, may use RAM)
        medium: Memory
        sizeLimit: 100Mi
```

`emptyDir` is Kubernetes' equivalent of Docker's anonymous volume — it lives as long as the Pod lives. Use it for scratch space and inter-container sharing within a Pod. For persistent data, use a PersistentVolumeClaim.

---

## Storage Drivers

Docker uses a **storage driver** to manage the OverlayFS layer stack. The default is `overlay2`, which is best for most Linux systems.

```bash
docker info | grep "Storage Driver"
# Storage Driver: overlay2
```

| Driver | Linux filesystems | Notes |
|--------|------------------|-------|
| `overlay2` | ext4, xfs (requires d_type=true) | Default, best performance |
| `overlay` | ext4, xfs | Older, requires kernel config |
| `devicemapper` | (any block device) | Legacy, complex, avoid |
| `btrfs` | btrfs | Good for btrfs systems |
| `zfs` | zfs | Good for ZFS systems |
| `vfs` | (any) | No copy-on-write, very slow — only for testing |

---

## Checkpoint

1. What is the difference between a named volume and a bind mount?
2. Where does Docker store named volumes on the host filesystem?
3. Why would you use `tmpfs` instead of a named volume for `/tmp`?
4. What happens to a named volume when you `docker rm` the container that used it?
5. What is the "volume precedence" gotcha when mounting a volume at a path the image already has content at?
6. Why is `--mount` syntax preferred over `-v` for production use?
7. What does `docker system df` show that `docker images` and `docker ps` don't?
8. How is `emptyDir` in Kubernetes similar to and different from a Docker named volume?
9. What is `--read-only` and what do you need alongside it for nginx to work?
10. What storage driver does Docker use by default on modern Linux, and what filesystem does it require?

➡ Next up: **Container Security** — now that we understand the container's filesystem and network, let's look at what actually prevents a container from escaping: Linux capabilities, seccomp, AppArmor, and rootless Docker.
