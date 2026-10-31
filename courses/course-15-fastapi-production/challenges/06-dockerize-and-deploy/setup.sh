#!/usr/bin/env bash
# Plants the "Dockerize & Deploy" FastAPI app + Dockerfile skeleton.
# Also creates the dojo-fastapi namespace in the current cluster.
# Idempotent — re-running overwrites files but does not remove the namespace.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/06-dockerize-and-deploy"
mkdir -p "$WORK/app"

# ── sanity checks ─────────────────────────────────────────────────────────────
if ! kubectl config current-context 2>/dev/null | grep -q 'kind-dojo'; then
    echo "WARNING: current kubectl context is not kind-dojo."
    echo "         Run: kubectl config use-context kind-dojo"
    echo "         Continuing anyway — namespace create may target the wrong cluster."
fi

# ── namespace ────────────────────────────────────────────────────────────────
kubectl create namespace dojo-fastapi --dry-run=client -o yaml | kubectl apply -f -

# ── app/main.py — complete, working FastAPI app ───────────────────────────────
cat > "$WORK/app/__init__.py" << 'PYEOF'
PYEOF

cat > "$WORK/app/main.py" << 'PYEOF'
from fastapi import FastAPI

app = FastAPI()


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/")
def root():
    return {"service": "dojo-fastapi", "version": "v1"}
PYEOF

# ── requirements.txt ──────────────────────────────────────────────────────────
cat > "$WORK/requirements.txt" << 'EOF'
fastapi==0.115.5
uvicorn[standard]==0.32.1
gunicorn==23.0.0
EOF

# ── Dockerfile skeleton ───────────────────────────────────────────────────────
cat > "$WORK/Dockerfile" << 'EOF'
# Dockerfile — complete the three TODO lines.
FROM python:3.12-slim

WORKDIR /srv

# TODO: COPY requirements.txt here and RUN pip install --no-cache-dir -r requirements.txt
# TODO: COPY app/ ./app/
# TODO: CMD that runs gunicorn with uvicorn worker on 0.0.0.0:8000

EXPOSE 8000
EOF

echo
echo "Work directory : $WORK"
echo
echo "Namespace dojo-fastapi created (or already exists)."
echo
echo "Steps:"
echo "  1. Complete the three TODO lines in $WORK/Dockerfile"
echo "  2. docker build -t dojo-fastapi:v1 $WORK"
echo "  3. kind load docker-image dojo-fastapi:v1 --name dojo"
echo "  4. kubectl apply -f your-deployment.yaml"
echo "  5. bash courses/course-15-fastapi-production/challenges/06-dockerize-and-deploy/verify.sh"
echo
echo "Prereqs: Docker Desktop running + kind-dojo context active."
