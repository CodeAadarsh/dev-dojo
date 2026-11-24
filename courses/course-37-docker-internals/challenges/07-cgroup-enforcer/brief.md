# Cgroup Enforcer

The app in `dojo-docker-cgroup` is running. No crash. No error. But it has **zero resource limits** — it can use 100% of every CPU on the node and all available memory.

In a shared cluster, this is a time bomb. One memory leak and the OOM killer starts evicting other pods. One CPU-hungry task and your latency-sensitive services start degrading.

Your job: add CPU and memory limits to the `hog` deployment so they're enforced by the kernel's cgroup subsystem.

## Mission

Apply resource limits to the `hog` Deployment in `dojo-docker-cgroup`:
- CPU: `100m` (0.1 cores)
- Memory: `128Mi`
- Also set matching requests (required for QoS class `Guaranteed`)

The verifier checks that the pod has both `requests` and `limits` set for CPU and memory.

## Why This Matters: cgroups

When you set `resources.limits.cpu: 100m` in Kubernetes, the kubelet writes to the kernel's **cgroup** filesystem:

```bash
# On the host node, inside the container's cgroup:
cat /sys/fs/cgroup/kubepods.slice/.../cpu.max
# 10000 100000
# ^ quota  ^ period (microseconds)
# 10000/100000 = 0.1 cores = 100m
```

cgroups (control groups) are a Linux kernel feature that limits, accounts for, and isolates resource usage of groups of processes. Docker uses cgroups for `--cpus`, `--memory`. Kubernetes maps `requests`/`limits` to cgroup entries via the kubelet.

```
Pod spec:                     Kernel cgroup:
  resources:              →   cpu.max: 10000 100000  (CPU throttle)
    limits:               →   memory.max: 134217728  (128 MiB, OOM kill threshold)
      cpu: 100m
      memory: 128Mi
```

Without limits, a container is in the `Burstable` or `BestEffort` QoS class — it gets whatever the node has left. With equal `requests` and `limits`, it's `Guaranteed` — the scheduler reserves the capacity and the cgroup enforces it.

## Setup

```bash
bash courses/course-37-docker-internals/challenges/07-cgroup-enforcer/setup.sh
```

## Verifying

```bash
bash courses/course-37-docker-internals/challenges/07-cgroup-enforcer/verify.sh
```
