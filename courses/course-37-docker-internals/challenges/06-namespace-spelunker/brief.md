# Namespace Spelunker

The security team has locked down the production host. `docker exec` is disabled via audit rules — any attempt to use it gets logged and triggers an incident. But you need to retrieve a secret from inside a running container to diagnose a live issue.

The flag is hidden at `/secret/flag.txt` inside the container `dojo-spelunker`. You can't use `docker exec`. You'll have to go deeper.

## Mission

Find the flag at `/secret/flag.txt` inside the container **without using `docker exec`**.

This is a **discovery** challenge — submit the flag string once you've retrieved it.

## Why This Works: Linux Namespaces

A container is not a virtual machine. It's just a Linux process running in a set of **namespaces** — kernel structures that give the process its own private view of system resources.

The *mount namespace* (`CLONE_NEWNS`) gives a process its own private filesystem view. When Docker creates a container, it creates a new mount namespace and mounts the container's rootfs there. That's why the container sees its own `/etc/hosts`, its own `/proc`, its own files.

But namespaces are not magic walls — they're just views. The host kernel can enter any namespace it owns using `nsenter`. If you have the PID of a container process and root access on the host, you can join its mount namespace and read its filesystem directly.

```
host process            container process
(your terminal)         (dojo-spelunker)
     │                        │
     │    nsenter -t <pid>     │
     │       --mount          │
     └────────────────────────►  now in the container's mount namespace
                                 cat /secret/flag.txt ← works!
```

## The Tool: nsenter

`nsenter` lets you enter one or more namespaces of a running process:

```bash
# Enter just the mount namespace (-m = mount, -t = target PID)
nsenter -t <pid> --mount <command>

# Enter all namespaces (network, pid, mount, etc.)
nsenter -t <pid> --mount --net --pid --ipc --uts <command>
```

## Setup

```bash
bash courses/course-37-docker-internals/challenges/06-namespace-spelunker/setup.sh
```

After setup, the container `dojo-spelunker` is running. Find its PID. Enter its mount namespace. Read the flag.

> **Challenge rule:** don't use `docker exec dojo-spelunker`. Use `nsenter` instead.
