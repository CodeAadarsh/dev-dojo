# Ship It: Gunicorn + Docker + k8s

The Flask dev-server — the one that logs `* Running on http://127.0.0.1:5000` — is single-threaded, reloads on every code change, and will crash under any real concurrency. Every production Flask deployment replaces it with a proper WSGI server. Gunicorn is the standard: pre-fork workers, graceful draining, and a decade of production hardening.

This challenge bridges the last three challenges into a full deployment pipeline: app code → container → cluster.

## Prerequisites

- Docker daemon running locally.
- A `kind` cluster named **`dojo`** (`kind create cluster --name dojo`).
- `kubectl` pointing at `kind-dojo`.

## Target state

The verifier checks four things in order:

| # | Check |
|---|-------|
| 1 | Namespace `dojo-flask` exists |
| 2 | A `Deployment` in `dojo-flask` has `readyReplicas >= 1` |
| 3 | The running pod's image contains the string `flask-app` (your local image name) |
| 4 | The Deployment spec has a `readinessProbe` targeting `GET /health` |

No flag until all four pass.

## Working directory

Setup writes everything you need into `$HOME/.kube-dojo-work/06-dockerize-and-deploy/`:

```
app.py          ← Flask app with /health endpoint
requirements.txt
Dockerfile      ← starter — read it, adjust if needed
```

## Mission

1. **Build the image** — name it `flask-app:dojo`.
2. **Load it into kind** — `kind load docker-image flask-app:dojo --name dojo`.
3. **Deploy to `dojo-flask`** — write and apply a `Deployment` + `Service` manifest:
   - Namespace: `dojo-flask`
   - Container image: `flask-app:dojo`
   - `imagePullPolicy: Never` (the image is local, not in a registry)
   - Gunicorn command: `["gunicorn", "-w", "2", "-b", "0.0.0.0:8000", "app:create_app()"]`
   - Container port: `8000`
   - `readinessProbe`: HTTP GET on `/health`, port `8000`
   - A `Service` of type `ClusterIP` on port `80` → target port `8000`

4. Run the verifier from the repo root: `bash courses/course-12-flask-production/challenges/06-dockerize-and-deploy/verify.sh`

## Why a readinessProbe on `/health`

Without it, Kubernetes marks a pod Ready the moment it starts — before Gunicorn has bound its socket and before your app has warmed up. The probe prevents traffic from reaching a pod that isn't serving. If a deploy goes bad (bad image, OOMKilled worker, import error), pods never become Ready and the rollout stalls instead of quietly routing errors.

> `imagePullPolicy: Never` tells the kubelet not to pull from a registry — it uses the image already in the node's image store. `kind load docker-image` is the step that gets it there. Forget it and the pod stays in `ErrImageNeverPull`.
