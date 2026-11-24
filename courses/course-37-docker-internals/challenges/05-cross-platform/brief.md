# Cross-Platform Build

It's Monday morning. The staging cluster paged at 7 AM: pod `api` in `dojo-docker-platform` is in `CrashLoopBackOff`. You look at the logs and find:

```
exec /app: exec format error
```

No crash. No bug. The binary just won't start. The developer built the image on their M2 MacBook — an `arm64` machine. The staging cluster runs `amd64` nodes. The kernel can't execute an ARM binary on an x86 CPU.

This is the "works on my machine" problem, but for CPU architecture.

## Mission

1. Diagnose why the pod is crashing (hint: look at the events and the platform annotation).
2. Build a correct `linux/amd64` image from the provided Dockerfile (in the ConfigMap).
3. Load it into the kind cluster and update the Deployment `api`.
4. Annotate the deployment: `kubectl annotate deployment api dojo.docker/fixed-platform=linux/amd64 -n dojo-docker-platform`

The verifier checks that at least one pod is Running AND the annotation is present.

## Why This Happens

Every ELF binary (compiled program) has a header that says what CPU architecture it was built for. The Linux kernel checks this header when it tries to run a file. An `arm64` binary on an `amd64` kernel → `exec format error`.

```
Your M2 Mac:           Staging cluster:
ARM64 CPU             AMD64 CPU
arm64 binary ✓        arm64 binary ✗  exec format error
```

Docker's `buildx` tool can cross-compile for different platforms, even from an ARM machine:

```bash
docker buildx build --platform linux/amd64 -t myapp:amd64 . --load
```

The `--platform` flag tells the builder to produce an `amd64` binary regardless of your host architecture. Under the hood, it uses QEMU emulation.

## Setup

```bash
bash courses/course-37-docker-internals/challenges/05-cross-platform/setup.sh
```

After setup, the broken Deployment is running in `dojo-docker-platform`. Check it:
```bash
kubectl describe pod -n dojo-docker-platform -l app=api
```

## Verifying

```bash
bash courses/course-37-docker-internals/challenges/05-cross-platform/verify.sh
```
