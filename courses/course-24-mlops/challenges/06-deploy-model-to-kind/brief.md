# Deploy Model to kind

The model-serving service from challenge 04 needs to go somewhere real. The platform team has a `kind` cluster standing by and a namespace reserved: `dojo-mlops`. Your task is to containerize the FastAPI server, load the image into the cluster, and wire it up with a Deployment and a Service — with a `/healthz` readinessProbe so Kubernetes can verify the pod is actually serving before routing traffic to it.

A platform ticket reads: *"Image build + load + apply — then verify.sh should confirm readyReplicas >= 1, the readinessProbe is defined, and the image matches what you loaded. This is the deployment pattern we expect for every model release."*

## Prerequisites

- Docker running locally
- A `kind` cluster named **`dojo`** (`kind create cluster --name dojo`)
- `kubectl` pointed at `kind-dojo` (`kubectl config use-context kind-dojo`)

## Context

`setup.sh` plants a working model-server project in your work directory:

```
~/.kube-dojo-work/06-deploy-model-to-kind/
├── app/
│   ├── main.py        # fully-implemented FastAPI server (no stubs)
│   ├── model.pkl      # trained Iris classifier (seeded)
│   ├── requirements.txt
│   └── Dockerfile     # WRITE THIS — skeleton provided
└── k8s/
    ├── deployment.yaml  # WRITE THIS — skeleton provided
    └── service.yaml     # WRITE THIS — skeleton provided
```

The `app/` code is complete and working — your job is the **Dockerfile** and the **Kubernetes manifests**, not the Python.

## Mission

### 1. Complete `app/Dockerfile`

```
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
```

Fill in the skeleton so the image:
- Uses `python:3.11-slim` as base
- Installs deps from `requirements.txt` before copying source (layer cache)
- Runs uvicorn on port **8080**

### 2. Build and load

```bash
IMAGE="dojo-model-server:v1"
docker build -t "$IMAGE" ~/.kube-dojo-work/06-deploy-model-to-kind/app/
kind load docker-image "$IMAGE" --name dojo
```

### 3. Deploy to `dojo-mlops`

Write `k8s/deployment.yaml` with:

| Field | Required value |
|-------|----------------|
| `namespace` | `dojo-mlops` |
| `image` | `dojo-model-server:v1` |
| `imagePullPolicy` | `IfNotPresent` |
| `containerPort` | `8080` |
| `readinessProbe` | HTTP GET `/healthz` on port 8080, `initialDelaySeconds: 5` |

Write `k8s/service.yaml` as a ClusterIP Service pointing to port 8080 in the same namespace.

Apply both:

```bash
kubectl apply -f ~/.kube-dojo-work/06-deploy-model-to-kind/k8s/
```

### 4. Verify readiness

```bash
kubectl -n dojo-mlops rollout status deployment/model-server
```

## What verify.sh checks

| Check | Pass condition |
|-------|---------------|
| Namespace exists | `dojo-mlops` present |
| Deployment exists | `model-server` in `dojo-mlops` |
| Ready replicas | `readyReplicas >= 1` |
| Image matches | Deployment pod spec uses `dojo-model-server:v1` |
| ReadinessProbe | `readinessProbe.httpGet.path == /healthz` in container spec |

## Why the readinessProbe is non-optional

Without a readinessProbe, Kubernetes marks a pod `Ready` the moment the container process starts — before uvicorn has bound the port or the model has loaded. During a rolling deployment, traffic routes to the new pod while it's still initializing: the first 2–3 seconds of real traffic hit a 500. The readinessProbe gates traffic until the HTTP check passes, making zero-downtime deploys actually zero-downtime.

## Verify

```bash
bash courses/course-24-mlops/challenges/06-deploy-model-to-kind/verify.sh
```

`readyReplicas >= 1` + probe present → flag printed.
