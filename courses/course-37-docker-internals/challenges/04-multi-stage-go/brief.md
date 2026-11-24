# Multi-Stage Go Build

The Go service is in production. The Docker image is **912 MB**. The binary inside it is **11 MB**.

You are shipping 901 MB of Go compiler, build cache, test tooling, and intermediate build artifacts that have zero business being in a production container. Every deploy pulls 912 MB across the network. Every node stores 912 MB per image. The attack surface includes the full Go toolchain.

Your job: use a multi-stage build to ship *only the binary* on a distroless base. Final image must be **under 20 MB**.

## Mission

1. Run the setup script — it creates a ConfigMap with the Go app source and a broken single-stage Dockerfile.
2. Write a multi-stage Dockerfile: compile in `golang:1.23-alpine`, ship the binary in `gcr.io/distroless/static-debian12:nonroot`.
3. Build the image, load it into the kind cluster, and deploy it as `go-app-slim` in `dojo-docker-multistage`.
4. Annotate the deployment: `kubectl annotate deployment go-app-slim dojo.docker/build-type=multi-stage -n dojo-docker-multistage`

The verifier checks that `go-app-slim` exists, is Running, and has the annotation.

## Why This Matters

A multi-stage build uses multiple `FROM` lines in one Dockerfile. Each `FROM` starts a fresh layer set. The trick is `COPY --from=<stage>`: copy just the artifact out of the fat build stage into a minimal runtime stage.

```dockerfile
# Stage 1: fat builder
FROM golang:1.23-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o /app ./...

# Stage 2: tiny runtime — only /app gets copied here
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /app /app
ENTRYPOINT ["/app"]
```

The final image contains: your binary + a CA bundle + timezone data. No shell. No package manager. No Go compiler. If an attacker gets RCE, they can't `curl | sh` because there's no `curl` and no `sh`.

## Setup

```bash
bash courses/course-37-docker-internals/challenges/04-multi-stage-go/setup.sh
```

Read the app source:
```bash
kubectl get configmap go-app-source -n dojo-docker-multistage -o jsonpath='{.data.main\.go}'
kubectl get configmap go-app-source -n dojo-docker-multistage -o jsonpath='{.data.go\.mod}'
```

## Verifying

```bash
bash courses/course-37-docker-internals/challenges/04-multi-stage-go/verify.sh
```
