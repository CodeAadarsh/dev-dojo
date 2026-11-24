# Solution: Cross-Platform Build

## Step 1 — Diagnose

```bash
kubectl describe pod -n dojo-docker-platform -l app=api
# Look at Events: ErrImagePull / ImagePullBackOff with "image not found"
# Also check annotations:
kubectl get deployment api -n dojo-docker-platform -o jsonpath='{.metadata.annotations}'
# Shows: dojo.docker/original-platform: linux/arm64
```

## Step 2 — Get the Dockerfile and app files

```bash
mkdir -p /tmp/dojo-api
kubectl get configmap api-dockerfile -n dojo-docker-platform \
  -o jsonpath='{.data.Dockerfile}' > /tmp/dojo-api/Dockerfile
kubectl get configmap api-dockerfile -n dojo-docker-platform \
  -o jsonpath='{.data.index\.html}' > /tmp/dojo-api/index.html
```

## Step 3 — Build for linux/amd64

```bash
# docker buildx ensures we produce an amd64 binary even on an arm64 Mac
docker buildx build \
  --platform linux/amd64 \
  -t dojo/api:amd64-fixed \
  /tmp/dojo-api/ \
  --load

# Verify the architecture
docker image inspect dojo/api:amd64-fixed --format '{{.Architecture}}'
# Should print: amd64
```

## Step 4 — Load into kind and update the Deployment

```bash
kind load docker-image dojo/api:amd64-fixed --name dojo

kubectl set image deployment/api api=dojo/api:amd64-fixed \
  -n dojo-docker-platform

kubectl annotate deployment api \
  dojo.docker/fixed-platform=linux/amd64 \
  -n dojo-docker-platform

kubectl rollout status deployment/api -n dojo-docker-platform
```

## Step 5 — Verify

```bash
bash courses/course-37-docker-internals/challenges/05-cross-platform/verify.sh
```

**Flag:** `KUBE{buildx_platform_linux_amd64}`

## Understanding exec format error

Every Linux ELF binary starts with a magic number (`\x7fELF`) followed by bytes that describe the target architecture. When the kernel's `execve()` syscall reads an ELF header with `EM_AARCH64` (ARM64) on an x86_64 machine, it returns `ENOEXEC` — "exec format error".

```
arm64 binary ELF header:
  Magic:    7f 45 4c 46  (ELF)
  Class:    64-bit
  Machine:  AArch64      ← kernel rejects this on amd64
```

## Preventing This in CI

```bash
# In your CI pipeline, always check what you built:
docker buildx imagetools inspect dojo/api:amd64-fixed | grep Platform

# Or add this gate:
ARCH=$(docker image inspect dojo/api:amd64-fixed --format '{{.Architecture}}')
[ "$ARCH" = "amd64" ] || { echo "Wrong arch: $ARCH"; exit 1; }
```

For images that need to run on both ARM (developer laptops) and AMD64 (CI/prod), build multi-arch and push a manifest list:
```bash
docker buildx build --platform linux/amd64,linux/arm64 -t dojo/api:v2 --push .
```
