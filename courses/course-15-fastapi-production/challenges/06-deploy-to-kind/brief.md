# Deploy to kind

The team has a working FastAPI service and wants it running in the dojo cluster. The Dockerfile
draft has two known issues: it runs as root and Python writes `.pyc` files on startup, which will
crash the container when `readOnlyRootFilesystem: true` is set. The Kubernetes manifests are
skeletons with `# TODO` placeholders.

Your job is to fix the Dockerfile, fill in the manifests, and prove the service is reachable and
healthy inside the cluster.

## Context

`setup.sh` plants the following in your work directory:

```
~/.kube-dojo-work/06-deploy-to-kind/
├── main.py              # complete FastAPI app with /health and /ready endpoints
├── requirements.txt     # pinned deps
├── Dockerfile           # draft — has two correctness issues to fix
├── .dockerignore        # pre-filled
└── k8s/
    ├── deployment.yaml  # skeleton — fill in the TODOs
    └── service.yaml     # skeleton — fill in the TODOs
```

## Prerequisites

- Docker Desktop running.
- kind cluster named `dojo` running: `kubectl config current-context` → `kind-dojo`.

```bash
kubectl config current-context   # must print kind-dojo
```

## Mission

The verifier checks, in order:

1. Namespace `dojo-fastapi` exists.
2. Deployment `fastapi-dojo` in `dojo-fastapi` has `availableReplicas >= 1`.
3. `GET /health` returns HTTP 200 (the verifier uses `kubectl port-forward` internally).
4. The deployment's `securityContext` has `readOnlyRootFilesystem: true`.

What you need to do:

**Dockerfile** — fix the two issues:
- Set `PYTHONDONTWRITEBYTECODE=1` so Python does not write `.pyc` files at startup.
- Add a non-root system user and switch to it with `USER` before `CMD`.

**k8s/deployment.yaml** — fill in:
- `image:` — the image name you build (e.g. `fastapi-dojo:1.0.0`).
- `imagePullPolicy: IfNotPresent` — required for `kind load docker-image`.
- `securityContext.readOnlyRootFilesystem: true`.
- `securityContext.runAsNonRoot: true`.
- A `tmpfs` emptyDir volume mounted at `/tmp` so Python still has scratch space.
- `readinessProbe` on `GET /health` port 8000.

**k8s/service.yaml** — fill in the selector to match the deployment's pod labels.

Build and deploy sequence:

```bash
cd ~/.kube-dojo-work/06-deploy-to-kind

# build
docker build -t fastapi-dojo:1.0.0 .

# load into kind (must match the image: field in deployment.yaml)
kind load docker-image fastapi-dojo:1.0.0 --name dojo

# apply
kubectl create namespace dojo-fastapi --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f k8s/

# watch until ready
kubectl rollout status deployment/fastapi-dojo -n dojo-fastapi
```

## Verify

```bash
bash courses/course-15-fastapi-production/challenges/06-deploy-to-kind/verify.sh
```

All checks pass → flag printed.
