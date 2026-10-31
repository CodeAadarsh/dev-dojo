# Solution — Deploy to kind

## Fixed `Dockerfile`

```dockerfile
# ── Stage 1: dependency builder ──────────────────────────────────────────────
FROM python:3.12-slim AS builder

WORKDIR /build
COPY requirements.txt .
RUN pip install --upgrade pip \
    && pip install --no-cache-dir --prefix=/install -r requirements.txt


# ── Stage 2: runtime ─────────────────────────────────────────────────────────
FROM python:3.12-slim AS runtime

WORKDIR /app

COPY --from=builder /install /usr/local
COPY . .

# Fix 1: prevent Python from writing .pyc files (would crash under readOnlyRootFilesystem)
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# Fix 2: run as a non-root system user
RUN addgroup --system app && adduser --system --ingroup app app
USER app

EXPOSE 8000

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
```

## Complete `k8s/deployment.yaml`

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: fastapi-dojo
  namespace: dojo-fastapi
spec:
  replicas: 1
  selector:
    matchLabels:
      app: fastapi-dojo
  template:
    metadata:
      labels:
        app: fastapi-dojo
    spec:
      containers:
      - name: api
        image: fastapi-dojo:1.0.0
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 8000
        readinessProbe:
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 5
          periodSeconds: 5
        resources:
          requests:
            cpu: "100m"
            memory: "64Mi"
          limits:
            cpu: "250m"
            memory: "128Mi"
        securityContext:
          readOnlyRootFilesystem: true
          runAsNonRoot: true
          allowPrivilegeEscalation: false
        volumeMounts:
        - name: tmp
          mountPath: /tmp
      volumes:
      - name: tmp
        emptyDir:
          medium: Memory
```

## Complete `k8s/service.yaml`

```yaml
apiVersion: v1
kind: Service
metadata:
  name: fastapi-dojo
  namespace: dojo-fastapi
spec:
  selector:
    app: fastapi-dojo
  ports:
  - port: 80
    targetPort: 8000
    protocol: TCP
  type: ClusterIP
```

## Build and deploy

```bash
cd ~/.kube-dojo-work/06-deploy-to-kind

docker build -t fastapi-dojo:1.0.0 .

kind load docker-image fastapi-dojo:1.0.0 --name dojo

kubectl create namespace dojo-fastapi --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f k8s/

kubectl rollout status deployment/fastapi-dojo -n dojo-fastapi
```

## Why each fix matters

**`PYTHONDONTWRITEBYTECODE=1`** — without this, CPython writes `.pyc` files into
`__pycache__/` directories adjacent to every `.py` file it imports. The first import of `main.py`
would attempt to write `/app/__pycache__/main.cpython-312.pyc` and fail with
`PermissionError: [Errno 13] Permission denied` because the container root is read-only.

**Non-root user** — `readOnlyRootFilesystem: true` and `runAsNonRoot: true` are independent
constraints but work together. A root process (UID 0) can still bypass some read-only filesystem
enforcement at the kernel level. A non-root user combined with a read-only root filesystem gives
defence-in-depth: even if an attacker achieves remote code execution, they cannot write to the
image filesystem or escalate privileges.

**`imagePullPolicy: IfNotPresent`** — `kind load docker-image` puts the image into each node's
container runtime store. `Always` would tell the kubelet to always try a registry pull, which
fails because there is no registry (the image only lives in the kind node store). `IfNotPresent`
tells the kubelet: "if the image is already present locally, use it."

**`emptyDir` at `/tmp`** — even with a read-only root filesystem, Python and many libraries
need to write temporary files. `emptyDir: {medium: Memory}` creates a `tmpfs` mount at `/tmp`
that survives the container's lifetime (destroyed when the pod is deleted) and is writable.
`medium: Memory` keeps it in RAM — no disk I/O, no persistence.

## Security hardening preview

In a real hardened deployment, add:
```yaml
securityContext:
  capabilities:
    drop: ["ALL"]
  seccompProfile:
    type: RuntimeDefault
```

`drop: ["ALL"]` removes all Linux capabilities from the container (network raw sockets,
chown, setuid, etc.). `RuntimeDefault` seccomp profile blocks ~300 dangerous syscalls. These
two lines alone eliminate a wide class of container escape techniques.
