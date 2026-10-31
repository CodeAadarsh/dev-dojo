# Production: Gunicorn, Docker & Kubernetes

> **Module 06 · Course 12** — `flask run` is how you test; it's not how you serve. This module covers the full path from `flask run` to a hardened container running in a kind cluster: gunicorn config, multi-stage Dockerfile, non-root + read-only filesystem, health probes, security headers, and deploying to kind. Each step has a corresponding failure mode you will recognise in production.

---

## WSGI vs ASGI

Flask is a **WSGI** application. WSGI (PEP 3333) is synchronous: one thread handles one request at a time. That's fine for most APIs. It becomes a bottleneck only when handlers block on I/O longer than your worker count can absorb.

The async alternative is **ASGI** (FastAPI + Uvicorn/Hypercorn). You don't need ASGI unless you're writing WebSocket handlers or genuine async I/O.

| | WSGI (Flask + Gunicorn) | ASGI (FastAPI + Uvicorn) |
|-|------------------------|--------------------------|
| Concurrency model | Threads / processes | Coroutines (asyncio) |
| Maturity | Production-hardened for 15+ years | Stable, rapidly growing |
| Use for | Standard request/response APIs | WebSockets, streaming, async I/O |
| Migration | None needed if already on Flask | Rewrite views to `async def` |

Flask 2.x added basic `async def` view support via `asgiref`, but it's experimental and not a reason to ditch Gunicorn.

---

## Gunicorn: workers, threads, timeouts

### Worker count

The classic formula is `(2 × CPU_count) + 1`. On a 2-core container that's 5. The rationale: some workers block on I/O while others serve requests, so more than CPU count helps; too many means the OS spends cycles context-switching with no throughput gain.

```python
# gunicorn.conf.py
import multiprocessing

workers = multiprocessing.cpu_count() * 2 + 1
threads = 2                  # per worker; useful when threads block briefly on DB
worker_class = "gthread"     # sync workers + threads; use "gevent" for high I/O
timeout = 30                 # SIGKILL a worker that takes > 30 s on one request
graceful_timeout = 30        # time to finish in-flight requests on SIGTERM
max_requests = 1000          # recycle workers to prevent memory leaks
max_requests_jitter = 50     # spread restarts out; prevents all workers recycling at once
bind = "0.0.0.0:8080"
accesslog = "-"              # stdout — the container runtime collects it
errorlog = "-"
loglevel = "info"
preload_app = True           # load app once before forking (copy-on-write saves RAM)
```

**`preload_app = True`:** the master process loads the app, forks workers, workers inherit code via copy-on-write — faster startup and lower RSS per worker. The caveat: DB connection pools are inherited by workers from the master's file descriptors. Close and reopen them post-fork:

```python
# gunicorn.conf.py
def post_fork(server, worker):
    from app.extensions import db
    db.engine.dispose()   # workers open their own connections
```

**`max_requests_jitter`:** if all 5 workers hit `max_requests = 1000` simultaneously they all restart at once, causing a brief latency spike. Jitter adds a random value in `[0, max_requests_jitter]` to each worker's counter, staggering the restarts.

### The timeout failure mode

`timeout = 30` means a worker holding a request for more than 30 seconds is SIGKILL'd. Symptoms in logs: `[CRITICAL] WORKER TIMEOUT (pid: 1234)`. The client gets a 502 or reset connection. The worker is replaced, and the cycle repeats if the slow path keeps being hit.

Gunicorn timeout is a backstop, not a substitute for I/O timeouts in application code. Set `httpx`/`requests` timeouts on every outbound call:

```python
import httpx

with httpx.Client(timeout=10.0) as client:   # total 10 s; raises TimeoutException
    resp = client.get("https://slow-upstream/api")
```

---

## Multi-stage Dockerfile

The goal: a small runtime image with no build tools or dev dependencies.

```dockerfile
# syntax=docker/dockerfile:1

# ── Stage 1: build ──────────────────────────────────────────────────────────
FROM python:3.12-slim AS builder

WORKDIR /build

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
# --prefix installs into /install; we copy that dir into the runtime stage
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# ── Stage 2: runtime ────────────────────────────────────────────────────────
FROM python:3.12-slim AS runtime

# Non-root user with a numeric UID — Kubernetes runAsNonRoot: true verifies by UID
RUN groupadd --gid 1001 appgroup && \
    useradd --uid 1001 --gid appgroup --no-create-home appuser

WORKDIR /app

# Copy installed packages from the build stage only
COPY --from=builder /install /usr/local

# Copy application code with correct ownership
COPY --chown=appuser:appgroup . .

# Create writable dirs now, while still root; everything else will be read-only
RUN mkdir -p /tmp/app && chown appuser:appgroup /tmp/app

USER appuser

EXPOSE 8080

# gunicorn picks up gunicorn.conf.py automatically if it's in the working directory
CMD ["gunicorn", "wsgi:app"]
```

```python
# wsgi.py
from app import create_app
app = create_app()
```

**Why numeric UID:** the Kubernetes `runAsNonRoot: true` security standard checks that `runAsUser != 0`. A user created with only a name (no UID) can still be UID 0 if the name resolves to root in `/etc/passwd`. A numeric UID is unambiguous.

**Why `--no-cache-dir`:** pip's download cache is useless inside an image layer; skipping it saves 50–200 MB depending on the dependency set.

**Why multi-stage:** the `builder` stage pulls in `build-essential` and gcc for any C-extension packages. The `runtime` stage gets none of that — just the compiled wheels. The final image is typically 200–400 MB smaller, with no build toolchain an attacker could leverage.

---

## readOnlyRootFilesystem

```yaml
securityContext:
  readOnlyRootFilesystem: true
  runAsNonRoot: true
  runAsUser: 1001
  allowPrivilegeEscalation: false
  capabilities:
    drop: ["ALL"]
```

With `readOnlyRootFilesystem: true`, any write to a path not mounted as a volume raises `Read-only file system` and terminates the process. Paths that commonly cause crashes:

- `/tmp` — used by many libraries for temporary files
- `/var/log` — if you write log files (don't; write to stdout)
- `__pycache__` — Python bytecode; set `PYTHONDONTWRITEBYTECODE=1` to skip it

The fix: mount writable `emptyDir` volumes for exactly the paths that need writes:

```yaml
spec:
  containers:
    - name: app
      securityContext:
        readOnlyRootFilesystem: true
      volumeMounts:
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: tmp
      emptyDir: {}
```

`emptyDir` lives on the node, is ephemeral (gone when the pod exits), and is writable. It's the correct target for any process that needs a scratch directory at runtime.

---

## Health endpoints

Two endpoints, two distinct responsibilities:

```python
# app/api/health.py
from flask import Blueprint, jsonify
from sqlalchemy import text
from app.extensions import db

health_bp = Blueprint("health", __name__)

@health_bp.route("/healthz")
def liveness():
    """Is the process alive? Keep this trivially cheap — no dependencies."""
    return jsonify({"status": "ok"}), 200

@health_bp.route("/readyz")
def readiness():
    """Can this pod serve traffic? Check DB connectivity."""
    try:
        db.session.execute(text("SELECT 1"))
        return jsonify({"status": "ok", "db": "connected"}), 200
    except Exception as exc:
        return jsonify({"status": "degraded", "db": str(exc)}), 503
```

**Liveness probe** (`/healthz`): Kubernetes restarts the pod when this fails. Keep it cheap — no DB, no network. A liveness probe that queries the DB will restart pods when the DB is slow, which is usually exactly the wrong time to restart.

**Readiness probe** (`/readyz`): Kubernetes removes the pod from the Service's endpoint list when this fails. Traffic stops going to it until it recovers. This is where you check dependencies. A pod that can't reach its DB should not receive traffic.

```yaml
livenessProbe:
  httpGet:
    path: /healthz
    port: 8080
  initialDelaySeconds: 5
  periodSeconds: 10
  failureThreshold: 3

readinessProbe:
  httpGet:
    path: /readyz
    port: 8080
  initialDelaySeconds: 5
  periodSeconds: 5
  failureThreshold: 3
```

`initialDelaySeconds: 5` gives gunicorn time to start before Kubernetes begins probing. Too low and the pod oscillates between `Ready` and `NotReady` during startup.

---

## Security headers

Flask-Talisman adds HTTP security headers in one call:

```python
# app/__init__.py
from talisman import Talisman

def create_app(config_name="default"):
    app = Flask(__name__)
    ...
    if not app.config.get("TESTING"):
        Talisman(
            app,
            force_https=False,               # TLS terminates at the ingress in K8s
            strict_transport_security=True,
            content_security_policy={
                "default-src": "'self'",
                "script-src": "'self'",
            },
            referrer_policy="strict-origin-when-cross-origin",
        )
    return app
```

`force_https=False` because in a Kubernetes cluster TLS terminates at the ingress or load balancer; the app runs on plain HTTP inside the cluster. Trying to force HTTPS from the app breaks health probes and cluster-internal traffic.

Verify headers are present:

```bash
curl -s -I http://localhost:8080/healthz | grep -E 'Strict|X-Content|X-Frame|Content-Security'
```

---

## Deploying to kind

The full flow — build, load, apply, verify:

```bash
# 1. Build with a pinned tag (never :latest in any manifest)
docker build -t flask-app:1.0.0 .

# 2. Load into every kind node (kind nodes have their own image store)
kind load docker-image flask-app:1.0.0 --name dojo

# 3. Apply all manifests
kubectl apply -f k8s/

# 4. Wait for rollout
kubectl -n dojo-flask rollout status deploy/flask-app --timeout=60s

# 5. Port-forward and test
kubectl -n dojo-flask port-forward svc/flask-app 8080:8080 &
sleep 2
curl -s http://localhost:8080/healthz
curl -s http://localhost:8080/readyz
kill %1
```

A minimal Deployment + Service:

```yaml
# k8s/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: dojo-flask
---
# k8s/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: flask-app
  namespace: dojo-flask
spec:
  replicas: 2
  selector:
    matchLabels:
      app: flask-app
  template:
    metadata:
      labels:
        app: flask-app
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1001
      containers:
        - name: app
          image: flask-app:1.0.0
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8080
          resources:
            requests:
              cpu: "100m"
              memory: "128Mi"
            limits:
              cpu: "500m"
              memory: "256Mi"
          securityContext:
            readOnlyRootFilesystem: true
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /readyz
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 5
          env:
            - name: PYTHONDONTWRITEBYTECODE
              value: "1"
            - name: PYTHONUNBUFFERED
              value: "1"
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir: {}
---
# k8s/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: flask-app
  namespace: dojo-flask
spec:
  selector:
    app: flask-app
  ports:
    - port: 8080
      targetPort: 8080
```

`imagePullPolicy: IfNotPresent` is required when loading images to kind — without it, Kubernetes tries to pull from a registry and fails because the image was loaded locally.

---

## Debugging Production Issues

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `[CRITICAL] WORKER TIMEOUT (pid: 1234)` in gunicorn logs | A request blocked longer than `timeout` seconds — slow DB query, external HTTP call with no timeout | Add timeouts to every I/O boundary in application code; increase gunicorn `timeout` as a stopgap, not a fix |
| Container exits immediately with `Read-only file system: '/app/__pycache__'` | `readOnlyRootFilesystem: true` and Python is writing `.pyc` files | Set `PYTHONDONTWRITEBYTECODE=1`; mount `/app/__pycache__` as `emptyDir` if bytecode caching is needed |
| Container OOM-killed (exit code 137) | Too many gunicorn workers, each with its own memory footprint; or a memory leak multiplied across workers | Reduce `workers`; cap `limits.memory`; identify the leak with `tracemalloc` or by watching RSS between requests |
| Pod stuck `ContainerCreating` — image not found | Image was never loaded into kind | `kind load docker-image <img>:<tag> --name dojo`, then `kubectl rollout restart deploy/<name> -n <ns>` |
| Readiness probe fails, pod never enters `Ready` | `/readyz` returning non-2xx; DB not ready yet on startup | Raise `initialDelaySeconds`; add a retry loop in the readiness handler; check `kubectl describe pod` for the exact probe failure message |
| `/healthz` starts failing after running fine for hours | Liveness probe is too aggressive (low `failureThreshold`, hits a transient error), or the handler itself blocks on a dependency it shouldn't | Keep liveness trivial (no DB); raise `failureThreshold`; check `kubectl events` for `Liveness probe failed` messages |

### Exact diagnosis commands

```bash
# Check why a pod won't start — Events section is the tell
kubectl -n dojo-flask describe pod <pod-name>

# Logs from the crashed container (pre-restart)
kubectl -n dojo-flask logs <pod-name> --previous

# Confirm the running process is non-root
kubectl -n dojo-flask exec <pod-name> -- id

# Confirm the filesystem is actually read-only
kubectl -n dojo-flask exec <pod-name> -- sh -c 'touch /test-rw 2>&1; echo "exit=$?"'
# Expect: touch: /test-rw: Read-only file system / exit=1

# Diagnose OOM
kubectl -n dojo-flask get pod <pod-name> \
  -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}{"\n"}'
# -> OOMKilled

# Watch gunicorn workers in real time
kubectl -n dojo-flask logs -f <pod-name> | grep -E 'WORKER|TIMEOUT|critical|error'

# Resource usage
kubectl -n dojo-flask top pod <pod-name>

# Hit health endpoints without an ingress
kubectl -n dojo-flask port-forward svc/flask-app 8080:8080 &
curl -s http://localhost:8080/healthz
curl -s http://localhost:8080/readyz
kill %1
```

> **War story.** A microservice at SAP had been stable for months until a new endpoint started calling a legacy internal API. Under load, the legacy API was occasionally slow — 25–40 seconds. Gunicorn's timeout was 30 seconds. On slow days, workers hit the new endpoint while the legacy API was sluggish, the workers timed out, gunicorn SIGKILL'd them, and the readiness probe started failing — leading to a pod restart cascade. The service was oscillating between Ready and NotReady, shedding traffic during each restart. Fix: a 10-second `httpx` timeout in the application code (fail fast with a 503 rather than blocking) and gunicorn `timeout = 60` as a backstop. Gunicorn timeout is a backstop, not a substitute for timeouts at every I/O boundary in your code.

---

## Checkpoint

You're ready for the challenge when you can:

1. Calculate the gunicorn worker count for a 4-core container and explain why `max_requests_jitter` prevents a thundering-herd restart.
2. Write a two-stage Dockerfile: a `builder` stage that `pip install`s, and a `runtime` stage that copies only the installed packages and app code — no build toolchain in the final image.
3. Add a non-root user with a numeric UID (1001) and switch to it before `CMD`.
4. Mount an `emptyDir` for `/tmp` in a Deployment spec and set `readOnlyRootFilesystem: true`; confirm the container can't write to `/` with `kubectl exec`.
5. Implement `/healthz` (liveness) and `/readyz` (readiness) with distinct responsibilities and configure both as Kubernetes probes.
6. Describe, without looking, what `[CRITICAL] WORKER TIMEOUT` means, how to reproduce it, and how to fix it at both the application and gunicorn levels.
7. Build an image, load it to kind, deploy it, and confirm `/healthz` returns 200 via `port-forward`.

➡ Next up: the **Slim and Safe** challenge — you'll Dockerize a Flask app with a non-root user and read-only filesystem, deploy it to kind, and prove health probes pass.
