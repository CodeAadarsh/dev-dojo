# Solution — Dockerize & Deploy: FastAPI to kind

Four artefacts to create: a complete `Dockerfile`, a `deployment.yaml`, and the two commands that bridge the image into the cluster.

## Complete Dockerfile

```dockerfile
FROM python:3.12-slim

WORKDIR /srv

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ ./app/

EXPOSE 8000

CMD ["gunicorn", "app.main:app", \
     "--worker-class", "uvicorn.workers.UvicornWorker", \
     "--bind", "0.0.0.0:8000", \
     "--workers", "2"]
```

## Build and load

```bash
cd ~/.kube-dojo-work/06-dockerize-and-deploy

docker build -t dojo-fastapi:v1 .

# Load into every kind node — required before any pod can use a local image
kind load docker-image dojo-fastapi:v1 --name dojo
```

## Kubernetes manifests

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
---
apiVersion: v1
kind: Service
metadata:
  name: fastapi
  namespace: dojo-fastapi
spec:
  selector:
    app: fastapi
  ports:
  - port: 80
    targetPort: 8000
```

```bash
kubectl apply -f deployment.yaml

# Watch until ready
kubectl rollout status deployment/fastapi -n dojo-fastapi
```

## Why each piece matters

**`python:3.12-slim` not `:latest`.** Pinning a tag makes builds reproducible. `:latest` means "whatever DockerHub serves today" — a different image on each CI run. `slim` omits the full Debian package set and shaves ~400 MB off the base.

**`--no-cache-dir` on pip.** The pip download cache is only useful for re-installs on the same machine. Inside a Docker layer it just bloats the image with files that will never be reused; strip it at build time.

**Gunicorn + UvicornWorker.** Running `uvicorn main:app --reload` is fine for development. In production you want:
- Gunicorn as the process manager: it restarts crashed workers, enforces `--timeout`, and handles SIGTERM/SIGKILL gracefully.
- Uvicorn workers for ASGI: `--worker-class uvicorn.workers.UvicornWorker` gives you asyncio-native request handling.
- `--workers 2` (or `2 * CPU + 1` as a rule of thumb): process-level parallelism so one slow request doesn't block the other worker.

**`imagePullPolicy: IfNotPresent`.** Without this, the kubelet may try to pull from the internet (defaulting to `Always` if the tag is `:latest`, and `IfNotPresent` only when the tag is explicit). Since kind nodes have the image loaded locally via `kind load`, you never want a pull attempt — it would fail with `ErrImagePull` because `dojo-fastapi:v1` doesn't exist on DockerHub.

**`readinessProbe`.** The probe is the contractual promise to Kubernetes: "don't send me traffic until I return 200 on /health." Without it, a pod that takes 5 seconds to start receives requests during that window and returns errors. The `initialDelaySeconds: 3` avoids probing before the ASGI server finishes binding.

## Attacker's view

The `Dockerfile` above runs as root inside the container — every process, every file write, all root. If the app has an RCE vulnerability, the attacker lands as root. Add a non-root user:

```dockerfile
RUN adduser --disabled-password --gecos '' appuser
USER appuser
```

Also: never `COPY . .` — it drags in `.git`, `.env`, credentials, and local `.venv` into the image layer. Be explicit about what you copy.
