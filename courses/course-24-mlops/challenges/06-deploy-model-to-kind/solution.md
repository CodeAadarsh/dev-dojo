# Solution — Deploy Model to kind

## Complete `app/Dockerfile`

```dockerfile
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8080
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
```

**Why `COPY requirements.txt` then `COPY .` separately?** Docker layers are cached by content hash. When only `main.py` changes, the `pip install` layer is already cached and rebuilds in seconds instead of minutes. Copying the entire source first invalidates the pip layer on every code change — a common beginner mistake that turns a 3-second rebuild into a 90-second one.

---

## Build and load

```bash
IMAGE="dojo-model-server:v1"
docker build -t "$IMAGE" ~/.kube-dojo-work/06-deploy-model-to-kind/app/

# Load into every kind node — kind clusters do not pull from your local daemon
kind load docker-image "$IMAGE" --name dojo

# Confirm the image landed on the control-plane node
docker exec dojo-control-plane crictl images | grep dojo-model-server
```

---

## Complete `k8s/deployment.yaml`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: model-server
  namespace: dojo-mlops
spec:
  replicas: 1
  selector:
    matchLabels:
      app: model-server
  template:
    metadata:
      labels:
        app: model-server
    spec:
      containers:
        - name: model-server
          image: dojo-model-server:v1
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8080
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10
```

## Complete `k8s/service.yaml`

```yaml
apiVersion: v1
kind: Service
metadata:
  name: model-server
  namespace: dojo-mlops
spec:
  selector:
    app: model-server
  ports:
    - port: 80
      targetPort: 8080
  type: ClusterIP
```

## Apply

```bash
# Create namespace idempotently
kubectl create ns dojo-mlops --dry-run=client -o yaml | kubectl apply -f -

# Apply both manifests
kubectl apply -f ~/.kube-dojo-work/06-deploy-model-to-kind/k8s/

# Watch rollout
kubectl -n dojo-mlops rollout status deployment/model-server
```

---

## Why each piece matters

**`imagePullPolicy: IfNotPresent`.** Without this, Kubernetes tries to pull `dojo-model-server:v1` from a registry — which doesn't exist. The pod lands in `ErrImagePull`. `IfNotPresent` tells the kubelet "use the local image store" — which is where `kind load` put it. Every locally-built image on kind needs this.

**`/healthz` readinessProbe.** The endpoint returns `{"status": "ok"}` only after `_model` is not None — meaning the model has fully deserialized. During a rolling deploy, the new pod receives traffic only after this probe passes. Without it, the first ~2 seconds of requests hit a pod that's still loading the model, returning 503.

**`initialDelaySeconds: 5`.** The model server takes ~3–4 seconds to cold start (pickle deserialization + uvicorn bind). Setting `initialDelaySeconds` below the actual startup time causes the probe to fail immediately and the pod to restart in a loop. 5 seconds is a safe lower bound for a ~50 KB pickle; for a 500 MB neural network you'd set it to 60+.

## Teardown

```bash
kubectl delete ns dojo-mlops
```
