# FastAPI in Production

> **Module 06 · Course 15** — A FastAPI app that works on your laptop is not a production service. This module covers the gap: how many workers to run and why, how to build a container that can't write to its own filesystem by design, what health endpoints Kubernetes actually calls and in what order, and how to get a trace ID into every log line without rewriting your entire app.

---

## uvicorn vs gunicorn + uvicorn workers

**uvicorn** alone is a single-process ASGI server. It is fine for development and for
containerized deployments where the orchestrator (Kubernetes) handles horizontal scaling by
running multiple replicas.

**gunicorn + uvicorn workers** runs a process manager (`gunicorn`) that spawns N uvicorn worker
processes. Each worker is a separate OS process with its own event loop, so it can use all CPU
cores on a single machine.

```
Gunicorn (master)
  ├── uvicorn worker 1  ← event loop, handles requests
  ├── uvicorn worker 2  ← event loop, handles requests
  ├── uvicorn worker 3  ← event loop, handles requests
  └── uvicorn worker 4  ← event loop, handles requests
```

The uvicorn worker class for gunicorn:

```bash
gunicorn main:app \
  --worker-class uvicorn.workers.UvicornWorker \
  --workers 4 \
  --threads 1 \
  --timeout 30 \
  --keep-alive 5 \
  --bind 0.0.0.0:8000
```

Worker count formula: `2 × CPU_cores + 1` for I/O-bound workloads. A 2-vCPU container → 5
workers. A 4-vCPU node → 9 workers. Do not exceed this unless you have profiled a specific
bottleneck — more workers mean more memory, more DB connections, and more context-switch overhead.

When to use which:

| Deployment | Use |
|-----------|-----|
| Kubernetes with HPA | `uvicorn` alone, 1 replica per pod, scale pods |
| VM or bare metal, want to use all cores | `gunicorn + UvicornWorker` |
| Local development | `uvicorn main:app --reload` |

`--timeout 30` is the critical parameter: if a worker does not respond in 30 seconds, gunicorn
kills it and spawns a replacement. Set this to your P99 response time plus a safety margin — too
low and you kill workers on legitimate slow queries; too high and a hung worker blocks that slot
indefinitely.

---

## Multi-Stage Dockerfile

A slim, secure Dockerfile for FastAPI. Two stages: builder (installs deps) → runtime (copies only
what's needed, drops root, locks the filesystem).

```dockerfile
# ── Stage 1: dependency builder ───────────────────────────────────────────────
FROM python:3.12-slim AS builder

WORKDIR /build

COPY requirements.txt .
RUN pip install --upgrade pip \
    && pip install --no-cache-dir --prefix=/install -r requirements.txt


# ── Stage 2: runtime image ────────────────────────────────────────────────────
FROM python:3.12-slim AS runtime

# Non-root user — never run as root in a container
RUN addgroup --system app && adduser --system --ingroup app app

WORKDIR /app

# Copy installed packages from builder
COPY --from=builder /install /usr/local
# Copy application code
COPY --chown=app:app . .

USER app

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8000

EXPOSE 8000

HEALTHCHECK --interval=10s --timeout=3s --retries=3 \
    CMD python3 -c "import httpx; httpx.get('http://localhost:${PORT}/health').raise_for_status()"

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1"]
```

`readOnlyRootFilesystem: true` in Kubernetes requires that the app writes nothing to the
container filesystem at runtime. Common violations:

- Python's `.pyc` cache: set `PYTHONDONTWRITEBYTECODE=1`
- `uvicorn` access log file: use `--log-level info` without `--log-filename` (stdout only)
- SQLite db files: do not embed SQLite in a read-only container; use a persistent volume or
  external DB
- Temp files: mount a `tmpfs` emptyDir at `/tmp` in the Pod spec

Kubernetes Pod spec for read-only root:

```yaml
containers:
- name: api
  image: myapp:1.0.0
  securityContext:
    readOnlyRootFilesystem: true
    runAsNonRoot: true
    runAsUser: 1000
    allowPrivilegeEscalation: false
  volumeMounts:
  - name: tmp
    mountPath: /tmp
volumes:
- name: tmp
  emptyDir:
    medium: Memory
```

---

## Health & Readiness Endpoints

Kubernetes calls two distinct probes:

| Probe | What it means | What happens on failure |
|-------|---------------|------------------------|
| `livenessProbe` | Is the process alive at all? | Pod is restarted |
| `readinessProbe` | Is the process ready to serve traffic? | Pod removed from Service endpoints |

These have different contracts. A pod should fail `readinessProbe` while it is warming up (loading
a model, running migrations), but should only fail `livenessProbe` if it is truly stuck (deadlock,
OOM). A liveness failure that triggers a restart is expensive; a readiness failure just drains traffic.

```python
from fastapi import FastAPI
from sqlalchemy.ext.asyncio import AsyncSession, create_async_engine

app = FastAPI()

@app.get("/health", status_code=200)
async def health():
    return {"status": "ok"}

@app.get("/ready", status_code=200)
async def ready(db: AsyncSession = Depends(get_db)):
    # Confirm the DB is reachable — if this fails, the pod is not ready to serve
    await db.execute(text("SELECT 1"))
    return {"status": "ready"}
```

`/health` should be a trivial 200 — no I/O, no dependencies. It answers "is uvicorn accepting
connections." `/ready` may include a lightweight DB ping, but keep it fast: a slow readiness check
delays rollouts. Never put business logic in either endpoint.

Kubernetes probe config:

```yaml
livenessProbe:
  httpGet:
    path: /health
    port: 8000
  initialDelaySeconds: 5
  periodSeconds: 10
readinessProbe:
  httpGet:
    path: /ready
    port: 8000
  initialDelaySeconds: 5
  periodSeconds: 5
  failureThreshold: 3
```

`initialDelaySeconds` gives the container time to start. Too low and the probe fires before
uvicorn is listening — Kubernetes kills the pod on the first liveness failure.

---

## Structured Logging

Print JSON. Always. Parsing human-readable log lines at scale is an ops tax; a JSON line is a
queryable document.

```python
import logging
import json
import sys
from datetime import datetime, timezone

class JSONFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        log: dict = {
            "ts": datetime.now(tz=timezone.utc).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "msg": record.getMessage(),
        }
        if record.exc_info:
            log["exc"] = self.formatException(record.exc_info)
        # merge any extra= kwargs passed to the logger call
        for key, value in record.__dict__.items():
            if key not in {
                "args", "asctime", "created", "exc_info", "exc_text",
                "filename", "funcName", "id", "levelname", "levelno",
                "lineno", "module", "msecs", "message", "msg", "name",
                "pathname", "process", "processName", "relativeCreated",
                "stack_info", "thread", "threadName",
            }:
                log[key] = value
        return json.dumps(log)

def configure_logging():
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JSONFormatter())
    root = logging.getLogger()
    root.handlers = [handler]
    root.setLevel(logging.INFO)
```

Inject a request ID via middleware so every log line from a request carries the same trace:

```python
import uuid
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request

class RequestIDMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        request_id = request.headers.get("X-Request-ID", str(uuid.uuid4()))
        # store on request.state for route handlers to read
        request.state.request_id = request_id
        response = await call_next(request)
        response.headers["X-Request-ID"] = request_id
        return response

app.add_middleware(RequestIDMiddleware)
```

A log line from a route:

```python
logger = logging.getLogger(__name__)

@router.get("/items/{item_id}")
async def get_item(item_id: int, request: Request):
    logger.info("item_fetch", extra={"request_id": request.state.request_id, "item_id": item_id})
    ...
```

Output in production: `{"ts":"2026-11-01T12:00:00+00:00","level":"INFO","msg":"item_fetch","request_id":"c7f3...","item_id":42}`

---

## OpenTelemetry Hooks

OpenTelemetry gives you distributed traces without changing your business logic. One line of
auto-instrumentation covers all FastAPI routes, SQLAlchemy queries, and httpx outgoing calls.

```bash
pip install opentelemetry-sdk \
    opentelemetry-instrumentation-fastapi \
    opentelemetry-instrumentation-sqlalchemy \
    opentelemetry-exporter-otlp-proto-grpc
```

```python
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.instrumentation.sqlalchemy import SQLAlchemyInstrumentor

def setup_telemetry(app, engine):
    exporter = OTLPSpanExporter(endpoint="http://otel-collector:4317", insecure=True)
    provider = TracerProvider()
    provider.add_span_processor(BatchSpanProcessor(exporter))
    trace.set_tracer_provider(provider)

    FastAPIInstrumentor.instrument_app(app)
    SQLAlchemyInstrumentor().instrument(engine=engine.sync_engine)
```

Call `setup_telemetry(app, engine)` after creating the app and before adding routes. Every
request now produces a span tree: `GET /items/{item_id}` → `SELECT items WHERE id = ?`. In
Grafana Tempo or Jaeger you can see the full request path across services.

---

## Deploying to a kind Cluster

Full workflow from code to running pod:

```bash
# 1. Build the image on your host
docker build -t fastapi-dojo:1.0.0 .

# 2. Load it into every kind node (kind has no access to your host's Docker registry)
kind load docker-image fastapi-dojo:1.0.0 --name dojo

# 3. Apply namespace + manifests
kubectl create namespace dojo-fastapi --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f k8s/
```

Minimal Deployment + Service:

```yaml
# k8s/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: fastapi-dojo
  namespace: dojo-fastapi
spec:
  replicas: 2
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
        imagePullPolicy: IfNotPresent    # required for kind-loaded images
        ports:
        - containerPort: 8000
        readinessProbe:
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 5
          periodSeconds: 5
        livenessProbe:
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 10
          periodSeconds: 10
        resources:
          requests:
            cpu: "100m"
            memory: "128Mi"
          limits:
            cpu: "500m"
            memory: "256Mi"
---
# k8s/service.yaml
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
  type: ClusterIP
```

`imagePullPolicy: IfNotPresent` is mandatory when using `kind load` — without it, the kubelet
tries to pull from a registry and fails with `ErrImagePull`.

Test from your host after applying:

```bash
kubectl port-forward -n dojo-fastapi svc/fastapi-dojo 8080:80 &
curl http://localhost:8080/health   # -> {"status":"ok"}
```

---

## Debugging FastAPI in Production

| Symptom | Cause | Fix |
|---------|-------|-----|
| `[CRITICAL] WORKER TIMEOUT` in gunicorn logs | Worker exceeded `--timeout`; a slow query or downstream call blocked it | Raise `--timeout`; profile slow endpoints; add async timeouts to outgoing calls (`httpx.AsyncClient(timeout=5)`) |
| Container starts then exits immediately with exit code 1 | `CMD` misconfigured (wrong module path, missing `main:app`); missing env var | `docker logs <container>`; test `docker run --rm -it myapp:1.0.0 sh` and run CMD manually |
| Container won't start with `readOnlyRootFilesystem: true` | App writes to a path at startup (Python cache, temp files, log files) | Set `PYTHONDONTWRITEBYTECODE=1`; mount `/tmp` as emptyDir; trace startup writes with `strace -e trace=openat,write` |
| `/health` returns 404 | Route not registered or path mismatch (`/healthz` vs `/health`) | `curl -v http://localhost:8000/health`; check router prefix; confirm the route is mounted on `app` not an unincluded sub-router |
| Pods crash-loop but `/health` responds 200 on manual test | Liveness probe fires before `initialDelaySeconds` expires, or probe timeout too short | Increase `initialDelaySeconds`; increase `timeoutSeconds` on the probe; check `kubectl describe pod` events |
| Log lines missing `request_id` in some routes | Middleware not applied globally, or a background task logs without the request context | Ensure middleware is added before routes; pass `request_id` explicitly into background task calls |
| OOM kill in production (exit code 137) | Worker process memory exceeds `limits.memory`; common with large JSON payloads | Profile with `tracemalloc`; add response streaming for large payloads; raise memory limit or reduce `--workers` |

> **War story.** A FastAPI service was deployed to a hardened Kubernetes cluster with `readOnlyRootFilesystem: true`. It passed all CI tests and pre-production review. The first time it ran in staging it crashed on startup: `PermissionError: [Errno 13] Permission denied: '/app/__pycache__'`. The Dockerfile's `COPY . .` had included the dev machine's `__pycache__` directories and Python tried to update them. The fix was two lines: `PYTHONDONTWRITEBYTECODE=1` in the Dockerfile and a `.dockerignore` entry for `**/__pycache__`. The lesson: test your container with `readOnlyRootFilesystem: true` locally before you ever reach staging — `docker run --read-only --tmpfs /tmp myapp:1.0.0` reproduces the constraint exactly.

---

## Checkpoint

You're ready for the challenge when you can, without looking anything up:

1. State the gunicorn worker count formula and what `--timeout` controls.
2. Name two `ENV` variables that prevent Python from writing files at runtime.
3. Explain the contract difference between `livenessProbe` and `readinessProbe` — when does each fire and what happens?
4. Write the `imagePullPolicy` value required for `kind load docker-image` to work and why.
5. Explain what `readOnlyRootFilesystem: true` enforces and the three most common startup failures it reveals.
6. Write the `kubectl port-forward` command to test a ClusterIP service named `fastapi-dojo` in namespace `dojo-fastapi` from your host.
7. Name the OTLPSpanExporter call and which two FastAPI/SQLAlchemy instrumentors to register for automatic distributed tracing.

➡ **Challenge 06 — Deploy to kind** tests exactly these skills. Run `setup.sh` to get the scaffold.
