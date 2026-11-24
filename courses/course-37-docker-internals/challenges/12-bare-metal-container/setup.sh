#!/usr/bin/env bash
set -euo pipefail

ROOTFS="/tmp/dojo-rootfs"

echo "==> Setting up challenge: Bare Metal Container"

# Idempotent: clean up stale rootfs if present
if [ -d "$ROOTFS" ]; then
  echo "    Cleaning up existing rootfs at $ROOTFS..."
  rm -rf "$ROOTFS"
fi

echo "    Extracting Alpine rootfs (requires Docker on host)..."
mkdir -p "$ROOTFS"
docker export "$(docker create alpine:3.20)" | tar -xC "$ROOTFS"

# Plant the flag
mkdir -p "$ROOTFS/secret"
printf 'KUBE{unshare_pivot_root_no_docker}' > "$ROOTFS/secret/flag.txt"
printf 'You found the rootfs! Now enter it properly with pivot_root or chroot to read /secret/flag.txt.\n' \
  > "$ROOTFS/secret/README.txt"

# Create a /proc mount point (needed inside the container)
mkdir -p "$ROOTFS/proc"
mkdir -p "$ROOTFS/dev"
mkdir -p "$ROOTFS/old-root"

echo ""
echo "==> Rootfs ready at $ROOTFS"
echo ""
echo "    The flag is hidden at $ROOTFS/secret/flag.txt"
echo "    But reading it directly from the host doesn't count."
echo ""
echo "    Your challenge: create a 'container' using Linux primitives so that"
echo "    the rootfs becomes / and you can read /secret/flag.txt from inside."
echo ""
echo "    Allowed tools: unshare, chroot, pivot_root, mount"
echo "    NOT allowed  : docker, nerdctl, podman, kubectl"
echo ""
echo "    TIP 1 (easy path)   : sudo chroot $ROOTFS /bin/sh"
echo "    TIP 2 (proper path) : sudo unshare --fork --pid --mount /bin/bash"
echo "                          then mount + pivot_root inside"
