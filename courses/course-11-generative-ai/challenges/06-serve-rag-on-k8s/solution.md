# Solution — Serve RAG on Kubernetes

## Step-by-step walkthrough

### 1. Run setup.sh

```bash
bash courses/course-11-generative-ai/challenges/06-serve-rag-on-k8s/setup.sh
```

This plants `app/` (FastAPI service + Dockerfile) and `k8s/` (manifests) in `~/.kube-dojo-work/06-serve-rag-on-k8s/`.

### 2. Build the Docker image

```bash
docker build -t rag-service:v1 ~/.kube-dojo-work/06-serve-rag-on-k8s/app
```

Verify the image built:
```bash
docker images rag-service
```

### 3. Load the image into kind

kind clusters run their own containerd daemon. Your local Docker daemon is invisible to it. `kind load` copies the image tarball across:

```bash
kind load docker-image rag-service:v1 --name dojo
```

Without this step, the pod gets `ErrImagePull` / `ImagePullBackOff` — one of the most common beginner gotchas when moving to kind.

### 4. Create the namespace

```bash
kubectl create namespace dojo-genai --dry-run=client -o yaml | kubectl apply -f -
```

The `--dry-run=client -o yaml | apply -f -` pattern is idempotent: it creates the namespace on first run and is a no-op on subsequent runs (no "already exists" error).

### 5. Apply the manifests

```bash
kubectl apply -f ~/.kube-dojo-work/06-serve-rag-on-k8s/k8s/
```

### 6. Wait for rollout

```bash
kubectl rollout status deployment/rag-service -n dojo-genai
```

Expected output: `deployment "rag-service" successfully rolled out`.

### 7. Smoke-test the service (optional)

```bash
kubectl port-forward svc/rag-service 8080:80 -n dojo-genai &
curl 'http://localhost:8080/search?q=kubernetes&k=2'
```

## Why each piece of the Deployment spec matters

**`imagePullPolicy: Never`**
Without this, kubelet tries to pull `rag-service:v1` from a registry (Docker Hub by default). The image does not exist there. Setting `Never` tells kubelet to use only what is already in the node's containerd image store — which is exactly what `kind load` put there.

**`readinessProbe` on `/health`**
The probe prevents traffic from reaching the pod until the FastAPI app has finished its startup. Without a readiness probe, `readyReplicas` would flip to 1 as soon as the container process starts, not when the HTTP server is listening. The verifier checks `readyReplicas >= 1`, so the probe also makes the challenge state accurate.

**`ClusterIP` Service**
Exposes the deployment inside the cluster on port 80 → 8080. `kubectl port-forward` tunnels through this for local testing. In a real staging environment you'd front this with an Ingress.

## Common failure modes

| Symptom | Root cause | Fix |
|---------|-----------|-----|
| `ErrImagePull` / `ImagePullBackOff` | Image not loaded into kind | `kind load docker-image rag-service:v1 --name dojo` |
| `ErrImagePull` with `ImagePullPolicy: Always` | Default pull policy for non-`:latest` tags differs | Ensure `imagePullPolicy: Never` in the spec |
| Pod in `CrashLoopBackOff` | App fails to start | `kubectl logs deploy/rag-service -n dojo-genai` |
| `readyReplicas` stays 0 | Readiness probe failing | Check probe path and port; `kubectl describe pod -n dojo-genai` |
| Verify passes but service returns 502 | Port-forward targeting wrong port | Port-forward to 80 (Service) not 8080 (Pod) |
