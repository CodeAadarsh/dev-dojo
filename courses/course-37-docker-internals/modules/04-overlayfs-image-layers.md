# OverlayFS — What's Actually on Disk

> **Module 04 · Course 37** — Every time you `docker pull nginx`, Docker downloads layers and stores them on disk. Every time you start a container, it gets a filesystem that looks like a complete Linux system — but it's not a copy. This module shows you how OverlayFS stacks read-only layers into one unified view, gives each container a thin writable layer on top, and why `rm bigfile` in a later RUN doesn't actually save space.

---

## The Core Idea: Stacking Read-Only Layers

A Docker image is not a single filesystem tarball. It's an ordered **stack of immutable layers**, assembled at runtime by OverlayFS into one unified view.

```
What you see (merged view):        What's actually on disk:
─────────────────────────          ─────────────────────────────────────
/app/server                        /var/lib/docker/overlay2/
/app/config.json                     <layer-hash-4>/diff/   ← COPY app/
/etc/nginx/nginx.conf                  app/
/usr/bin/python3                       └── server
/lib/x86_64-linux-gnu/libc.so          └── config.json
                                     <layer-hash-3>/diff/   ← RUN pip install
                                       usr/
                                       └── local/lib/python3.11/
                                     <layer-hash-2>/diff/   ← RUN apt-get install
                                       usr/bin/python3
                                       lib/x86_64-linux-gnu/libc.so
                                     <layer-hash-1>/diff/   ← FROM debian:slim
                                       bin/  etc/  lib/  ...
```

The kernel sees these as separate directories on disk. OverlayFS overlays them (bottom to top) so your container process sees a single merged filesystem.

---

## OverlayFS Terminology

OverlayFS has four key concepts:

| Term | What it is | Mutable? |
|------|-----------|---------|
| **lowerdir** | The read-only image layers, stacked bottom-to-top | No — shared by all containers using this image |
| **upperdir** | The writable layer, unique to this container | Yes — each container has its own |
| **workdir** | Internal scratch space for OverlayFS bookkeeping | Managed by kernel |
| **merged** | The unified view your container process sees | Effectively yes (via CoW) |

```
merged/      ← container sees this: the union of everything below
    │
    ├── upperdir/   ← changes go HERE (created files, modified files, deletions)
    │
    └── lowerdir/   ← read-only stack (bottom = base image, top = most recent layer)
            lowerdir[N]   (most recent layer, e.g., COPY app/)
            lowerdir[N-1] (e.g., RUN pip install)
            ...
            lowerdir[0]   (base image layer)
```

---

## The Actual Mount Command Docker Uses

Under the hood, Docker calls `mount` like this:

```bash
mount -t overlay overlay \
  -o lowerdir=/var/lib/docker/overlay2/abc123/diff:/var/lib/docker/overlay2/def456/diff:/var/lib/docker/overlay2/ghi789/diff,\
     upperdir=/var/lib/docker/overlay2/xyz001/diff,\
     workdir=/var/lib/docker/overlay2/xyz001/work \
  /var/lib/docker/overlay2/xyz001/merged
```

The `lowerdir` is a colon-separated list of directories, **left = top of stack** (most recent layer). The first one wins if a file exists in multiple layers.

---

## Copy-on-Write (CoW): Reading vs Writing

**Reading a file:** OverlayFS finds the file in the highest layer that has it, and returns it directly. No copying. This is why starting 100 containers from the same image is fast — they all read from the same `lowerdir`.

**Writing a file for the first time:** OverlayFS copies the file from `lowerdir` to `upperdir`, then lets you modify the copy. The original in `lowerdir` is unchanged. This is the "copy-on-write" part.

```
Before writing /etc/nginx/nginx.conf:
  merged/etc/nginx/nginx.conf  → reads from lowerdir[1]/etc/nginx/nginx.conf

After writing (container modifies the file):
  upperdir/etc/nginx/nginx.conf  ← new copy, with your changes
  merged/etc/nginx/nginx.conf    → now reads from upperdir (shadows lowerdir)
  lowerdir[1]/etc/nginx/nginx.conf  ← original, unchanged
```

**Deleting a file:** OverlayFS creates a **whiteout** file in `upperdir`. A whiteout is a special device file (char device, major=0, minor=0) that tells OverlayFS "pretend this path doesn't exist."

```bash
# See whiteout files
ls -la $(docker inspect <id> --format '{{.GraphDriver.Data.UpperDir}}')
# crw------- 1 root root 0, 0 Nov 25 12:00 deleted_file  ← whiteout
```

---

## Why `rm bigfile` in a Later Layer Doesn't Help

This is the most common "my image is 2 GB" bug.

```dockerfile
# This is wrong — bigfile is in layer 2, the bytes still ship
FROM ubuntu:22.04                    # layer 1: 70 MB
RUN apt-get install -y build-essential && \
    ./compile_something.sh           # layer 2: adds bigfile.o (500 MB)
RUN rm bigfile.o                     # layer 3: whiteout in upperdir — file "hidden" but bytes still in layer 2!
```

```
Final image layers shipped:
  layer 3: 0 bytes (just a whiteout entry)
  layer 2: 500 MB  ← still here! you paid the bytes.
  layer 1: 70 MB
  TOTAL: 570 MB shipped, even though the file is "deleted"
```

**The fix:** Delete in the **same** `RUN` instruction that created the file:

```dockerfile
FROM ubuntu:22.04
RUN apt-get install -y build-essential && \
    ./compile_something.sh && \
    rm bigfile.o                     # same layer — file never committed to a layer blob
```

Same reasoning applies to `apt-get` cache:

```dockerfile
# Wrong: cache lands in its own layer
RUN apt-get update
RUN apt-get install -y curl
RUN rm -rf /var/lib/apt/lists/*   # too late, cache is already in layer 2

# Right: all one layer, cache cleaned before commit
RUN apt-get update && \
    apt-get install -y curl && \
    rm -rf /var/lib/apt/lists/*
```

---

## Inspecting Layers on Disk

```bash
# Start a container
docker run -d --name overlay-test nginx:1.27-alpine

# Find the graph driver data for this container
docker inspect overlay-test --format '{{json .GraphDriver.Data}}' | python3 -m json.tool
# {
#   "LowerDir": "/var/lib/docker/overlay2/abc.../diff:/var/lib/docker/overlay2/def.../diff:...",
#   "MergedDir": "/var/lib/docker/overlay2/xyz.../merged",
#   "UpperDir": "/var/lib/docker/overlay2/xyz.../diff",
#   "WorkDir": "/var/lib/docker/overlay2/xyz.../work"
# }

# See the merged view (what the container sees as its filesystem)
MERGED=$(docker inspect overlay-test --format '{{.GraphDriver.Data.MergedDir}}')
ls $MERGED
# bin  dev  etc  home  lib  media  mnt  opt  proc  root  run  srv  sys  tmp  usr  var

# See the upper dir (writable layer — initially nearly empty)
UPPER=$(docker inspect overlay-test --format '{{.GraphDriver.Data.UpperDir}}')
ls -la $UPPER
# (nearly empty on a fresh container)

# Write something in the container, then inspect the upper dir
docker exec overlay-test sh -c 'echo "hello" > /test.txt'
ls $UPPER
# test.txt  ← appears here!

# Clean up
docker rm -f overlay-test
```

---

## Layer Content-Addressing

Each layer is identified by a **sha256 digest** of its content. Two images that share a base layer share the **same bytes on disk** — stored once, used by many.

```bash
# nginx and alpine might share the same base layer
docker pull nginx:1.27-alpine
docker pull python:3.12-alpine

# Check image layer digests
docker image inspect nginx:1.27-alpine --format '{{json .RootFS.Layers}}'
# ["sha256:abc...", "sha256:def...", "sha256:ghi..."]

docker image inspect python:3.12-alpine --format '{{json .RootFS.Layers}}'
# ["sha256:abc...", "sha256:xyz...", ...]  ← "abc" is the same alpine base layer!

# See total disk usage, deduplicating shared layers
docker system df
# Images: 5, 320MB, 180MB shared — only 140MB unique
```

---

## docker history: Seeing Per-Layer Sizes

```bash
docker history nginx:1.27-alpine
# IMAGE          CREATED       CREATED BY                                      SIZE
# a7b2c3d4e5f6   2 weeks ago   /bin/sh -c #(nop)  CMD ["nginx" "-g" "daemon…   0B
# <missing>      2 weeks ago   /bin/sh -c #(nop)  EXPOSE 80                    0B
# <missing>      2 weeks ago   /bin/sh -c #(nop)  ENTRYPOINT ["/docker-entr…   0B
# <missing>      2 weeks ago   /bin/sh -c set -x && addgroup -g 101 -S ngin…   7.76MB
# <missing>      2 weeks ago   /bin/sh -c #(nop)  ENV PKG_RELEASE=1~bookworm   0B
# <missing>      2 weeks ago   /bin/sh -c apk add --no-cache nginx              3.69MB
# <missing>      3 weeks ago   /bin/sh -c #(nop)  FROM alpine:3.20             7.37MB
```

Notice:
- `ENV`, `CMD`, `EXPOSE`, `ENTRYPOINT` instructions create **0-byte metadata layers** — they don't add filesystem content
- `RUN` and `COPY`/`ADD` create real layers with actual bytes
- `--no-trunc` shows the full instruction text

---

## Layer Storage Layout on Disk

```bash
ls /var/lib/docker/overlay2/
# abc123def456.../   ← one directory per image layer
# xyz789.../
# l/                 ← symlinks with short names (avoids mount option length limits)
#   ABCDEF -> ../abc123def456.../diff
#   GHIJKL -> ../xyz789.../diff

ls /var/lib/docker/overlay2/abc123def456.../
# committed  diff/  link  lower  work/
# └── diff/    ← the actual filesystem content of this layer
# └── link     ← the short name in l/ for this layer
# └── lower    ← colon-separated list of parent layers (by short name)
# └── committed ← marker file: layer is immutable
```

---

## Checkpoint

1. What are lowerdir, upperdir, workdir, and merged in OverlayFS?
2. When a container process reads a file, does OverlayFS copy it? When does it copy?
3. Why does `rm bigfile` in a separate `RUN` instruction not reduce image size?
4. How do you fix the "cleanup in a later layer" problem?
5. If 10 containers run from the same image, how many copies of the image layers exist on disk?
6. What is a whiteout file and when does OverlayFS create one?
7. What command shows you the size of each layer in an image?
8. Where does the upperdir (writable layer) go when a container is removed?
9. What does `docker system df` tell you that `docker images` doesn't?
10. Why do `ENV`, `CMD`, and `EXPOSE` instructions produce 0-byte layers?

➡ Next up: **Dockerfile Mastery** — now that you understand what every instruction does at the layer level, let's go deeper on the instructions that trip up experienced developers: ARG vs ENV, SHELL form vs exec form, BuildKit secrets and cache mounts.
