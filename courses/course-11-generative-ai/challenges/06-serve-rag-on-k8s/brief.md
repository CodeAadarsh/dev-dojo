# Serve RAG on Kubernetes

The prototype RAG service passed code review. The infra ticket is open: *"containerise and deploy to the staging cluster. Namespace dojo-genai. No external dependencies — the service must be self-contained. SRE will verify a readyReplicas >= 1 before cutting DNS."*

This challenge bridges the previous Python work into Kubernetes reality. The service code is provided — your job is the delivery pipeline: build, load, manifest, deploy.

## Prerequisites

- Docker (daemon running)
- kind cluster named `dojo` (`kind create cluster --name dojo` if it does not exist)
- `kubectl` configured with context `kind-dojo` (`kubectl config use-context kind-dojo`)
- `python3`, `pip install numpy fastapi uvicorn` (only needed to inspect the service locally)

## Work directory layout

`setup.sh` plants the following in `~/.kube-dojo-work/06-serve-rag-on-k8s/`:

```
app/
  main.py           # FastAPI RAG service — in-memory corpus, cosine search, no LLM
  requirements.txt  # fastapi, uvicorn, numpy
  Dockerfile        # ready to build — do not edit
k8s/
  deployment.yaml   # Deployment spec — image: rag-service:v1, imagePullPolicy: Never
  service.yaml      # ClusterIP Service on port 80 -> 8080
```

## Mission

Complete the following steps in order:

**1. Build the image**
```bash
docker build -t rag-service:v1 ~/.kube-dojo-work/06-serve-rag-on-k8s/app
```

**2. Load the image into the kind cluster**

kind clusters do not pull from a local daemon — you must explicitly load the image:
```bash
kind load docker-image rag-service:v1 --name dojo
```

**3. Create the namespace**
```bash
kubectl create namespace dojo-genai --dry-run=client -o yaml | kubectl apply -f -
```

**4. Deploy**
```bash
kubectl apply -f ~/.kube-dojo-work/06-serve-rag-on-k8s/k8s/
```

**5. Wait for the pod to be Running**
```bash
kubectl rollout status deployment/rag-service -n dojo-genai
```

## What the verifier checks

| Check | Pass condition |
|-------|---------------|
| Namespace exists | `dojo-genai` present |
| Deployment exists | at least one Deployment in `dojo-genai` |
| Ready replicas | `readyReplicas >= 1` |
| Correct image | container image == `rag-service:v1` |

## Why `imagePullPolicy: Never` matters

By default Kubernetes tries to pull images from a registry. A kind cluster has its own containerd daemon — it cannot see your local Docker daemon. `kind load docker-image` copies the image into the containerd daemon, but only if the Deployment's `imagePullPolicy` is `Never` (or `IfNotPresent` with the image already present). Without it, Kubernetes issues an `ErrImagePull` / `ImagePullBackOff` even though `docker images` shows the image. The provided `deployment.yaml` already sets this correctly.

## Verify

```bash
bash courses/course-11-generative-ai/challenges/06-serve-rag-on-k8s/verify.sh
```
