# Dockerize & Deploy — FastAPI to kind

The infrastructure team just handed you a Jira ticket: *"Containerize the FastAPI auth service and get it running in the dojo cluster. It needs a /health endpoint the kubelet can probe, a slim image (no dev deps), and it must survive a readiness check before we route traffic."*

`setup.sh` plants a working FastAPI app and a `Dockerfile` skeleton in your work directory. Your job: complete the Dockerfile, build the image, load it into the kind cluster, and deploy it to Kubernetes with a proper readinessProbe.

## Prerequisites

- Docker Desktop running (`docker ps` works)
- kind `dojo` cluster running (`kubectl config current-context` → `kind-dojo`)
- Namespace `dojo-fastapi` will be created by setup.sh

## Context

`setup.sh` plants this layout:

```
~/.kube-dojo-work/06-dockerize-and-deploy/
├── app/
│   └── main.py          # working FastAPI app with /health endpoint
├── Dockerfile           # skeleton — complete it
└── requirements.txt
```

## Mission

Complete and run these steps:

### Step 1 — Build the image

```bash
cd ~/.kube-dojo-work/06-dockerize-and-deploy
docker build -t dojo-fastapi:v1 .
```

The Dockerfile skeleton uses `python:3.12-slim` as the base. You need to:
- `COPY requirements.txt` and `RUN pip install --no-cache-dir -r requirements.txt`
- `COPY app/ ./app/`
- Set `CMD` to run gunicorn with a uvicorn worker: `["gunicorn", "app.main:app", "--worker-class", "uvicorn.workers.UvicornWorker", "--bind", "0.0.0.0:8000", "--workers", "2"]`

### Step 2 — Load the image into kind

```bash
kind load docker-image dojo-fastapi:v1 --name dojo
```

Kind nodes never pull from your local Docker daemon. `kind load` copies the image into every node's containerd image store. Without this step, pods will be stuck `ErrImagePull`.

Set `imagePullPolicy: IfNotPresent` in your Deployment — it tells the kubelet to use the locally-loaded image instead of going to a registry.

### Step 3 — Deploy to Kubernetes

Apply a Deployment + Service to namespace `dojo-fastapi`:

```yaml
# deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: fastapi
  namespace: dojo-fastapi
spec:
  replicas: 1
  selector:
    matchLabels:
      app: fastapi
  template:
    metadata:
      labels:
        app: fastapi
    spec:
      containers:
      - name: fastapi
        image: dojo-fastapi:v1
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 8000
        readinessProbe:
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 3
          periodSeconds: 5
```

The `readinessProbe` is non-negotiable — the verifier checks for it. Without it, Kubernetes routes traffic to a pod that may still be booting. The `/health` endpoint must return HTTP 200; the skeleton already implements it.

### Step 4 — Verify

```bash
bash courses/course-15-fastapi-production/challenges/06-dockerize-and-deploy/verify.sh
```

The verifier checks:
1. Deployment `fastapi` in namespace `dojo-fastapi` exists and `readyReplicas >= 1`.
2. The pod is running image `dojo-fastapi:v1`.
3. A `readinessProbe` with `httpGet.path = /health` is configured on the container.

All three conditions green → flag printed.

## Why this matters

The gap between "it works on my laptop with uvicorn directly" and "it runs in production" is mostly this sequence: containerize with a production-grade WSGI/ASGI server (not `uvicorn --reload`), shrink the image (no dev tools, no `.git`, no `.venv`), load into the cluster, and prove it's healthy before traffic hits it. The readinessProbe is the contractual boundary: the cluster will not send traffic to a pod that hasn't passed it, even if the container started.
