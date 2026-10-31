#!/usr/bin/env bash
# Plants the "Serve RAG on Kubernetes" challenge:
#   app/  — FastAPI RAG service + Dockerfile
#   k8s/  — Deployment + Service manifests
# No LLM required.  Docker + kind cluster named "dojo" required.
set -euo pipefail

SLUG="06-serve-rag-on-k8s"
WORK="$HOME/.kube-dojo-work/$SLUG"
mkdir -p "$WORK/app" "$WORK/k8s"

# ── app/requirements.txt ──────────────────────────────────────────────────────
cat > "$WORK/app/requirements.txt" << 'EOF'
fastapi==0.115.5
uvicorn==0.32.1
numpy==2.1.3
EOF

# ── app/main.py ───────────────────────────────────────────────────────────────
# Minimal RAG HTTP service: in-memory corpus, cosine similarity search endpoint.
# No external LLM required — returns retrieved document context only.
cat > "$WORK/app/main.py" << 'PYEOF'
"""
Minimal RAG service — in-memory vector store, cosine similarity search.
No external LLM dependency.  Returns retrieved context as JSON.

GET /search?q=<query-text>&k=<int>  ->  {"query": ..., "results": [...]}
GET /health                          ->  {"status": "ok"}
"""

from __future__ import annotations

import math
from typing import List

from fastapi import FastAPI, Query

app = FastAPI(title="rag-service")

# ── in-memory corpus ──────────────────────────────────────────────────────────
_DOCS = [
    "Python list comprehensions, generators, and functools for composable data pipelines",
    "Kubernetes pod scheduling, node affinity, taints, tolerations, and resource limits",
    "Retrieval-augmented generation: dense retrieval, reranking, and context packing",
    "PostgreSQL query planning, EXPLAIN ANALYZE, index types, and vacuum configuration",
    "Docker multi-stage builds, BuildKit cache mounts, and distroless base images",
    "Prometheus metrics, recording rules, and alert routing with Alertmanager",
    "Redis data structures, expiry policies, Lua scripting, and cluster replication",
    "OAuth2, JWT validation, mTLS, and secrets management in a zero-trust mesh",
]

# Synthetic 8-dimensional embeddings (dimension = topic affinity)
# dim: 0=Python 1=K8s 2=RAG 3=Postgres 4=Docker 5=Prometheus 6=Redis 7=Security
_EMBEDDINGS = [
    [10.0, 0.5, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
    [0.5, 10.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
    [0.0, 0.0, 10.0, 0.5, 0.0, 0.0, 0.0, 0.0],
    [0.0, 0.0, 0.5, 10.0, 0.0, 0.0, 0.0, 0.0],
    [0.0, 0.0, 0.0, 0.0, 10.0, 0.5, 0.0, 0.0],
    [0.0, 0.0, 0.0, 0.0, 0.5, 10.0, 0.0, 0.0],
    [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 10.0, 0.5],
    [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.5, 10.0],
]

# Simple keyword -> embedding vector for the search endpoint demo
_KEYWORD_DIMS = {
    "python": 0, "kubernetes": 1, "k8s": 1, "rag": 2, "retrieval": 2,
    "postgres": 3, "postgresql": 3, "docker": 4, "prometheus": 5,
    "redis": 6, "security": 7, "auth": 7, "oauth": 7,
}


def _query_to_vec(text: str) -> List[float]:
    """Map query text to an 8-dim vector via keyword dims (good enough for demo)."""
    vec = [0.0] * 8
    for word in text.lower().split():
        dim = _KEYWORD_DIMS.get(word.strip(",.;:?!"))
        if dim is not None:
            vec[dim] += 9.0
    # If no keyword matched, give uniform signal
    if all(v == 0.0 for v in vec):
        vec = [1.0] * 8
    return vec


def _cosine(a: List[float], b: List[float]) -> float:
    dot = sum(x * y for x, y in zip(a, b))
    norm_a = math.sqrt(sum(x * x for x in a))
    norm_b = math.sqrt(sum(x * x for x in b))
    if norm_a == 0.0 or norm_b == 0.0:
        return 0.0
    return dot / (norm_a * norm_b)


def _retrieve(query_vec: List[float], k: int) -> List[int]:
    scores = [_cosine(query_vec, emb) for emb in _EMBEDDINGS]
    return sorted(range(len(scores)), key=lambda i: scores[i], reverse=True)[:k]


# ── endpoints ─────────────────────────────────────────────────────────────────

@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/search")
def search(
    q: str = Query(..., description="Query text"),
    k: int = Query(3, ge=1, le=len(_DOCS), description="Number of results"),
):
    query_vec = _query_to_vec(q)
    indices = _retrieve(query_vec, k)
    return {
        "query": q,
        "results": [{"rank": rank + 1, "doc_id": idx, "text": _DOCS[idx]}
                    for rank, idx in enumerate(indices)],
    }
PYEOF

# ── app/Dockerfile ────────────────────────────────────────────────────────────
cat > "$WORK/app/Dockerfile" << 'EOF'
FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .

EXPOSE 8080
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
EOF

# ── k8s/deployment.yaml ───────────────────────────────────────────────────────
cat > "$WORK/k8s/deployment.yaml" << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rag-service
  namespace: dojo-genai
  labels:
    app: rag-service
    challenge: 06-serve-rag-on-k8s
spec:
  replicas: 1
  selector:
    matchLabels:
      app: rag-service
  template:
    metadata:
      labels:
        app: rag-service
    spec:
      containers:
        - name: rag-service
          image: rag-service:v1
          # MUST be Never for kind-loaded images — without this Kubernetes
          # tries to pull from a registry and gets ImagePullBackOff.
          imagePullPolicy: Never
          ports:
            - containerPort: 8080
          readinessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 5
EOF

# ── k8s/service.yaml ──────────────────────────────────────────────────────────
cat > "$WORK/k8s/service.yaml" << 'EOF'
apiVersion: v1
kind: Service
metadata:
  name: rag-service
  namespace: dojo-genai
spec:
  selector:
    app: rag-service
  ports:
    - port: 80
      targetPort: 8080
  type: ClusterIP
EOF

echo
echo "Work directory : $WORK"
echo
echo "Steps          :"
echo "  1. docker build -t rag-service:v1 $WORK/app"
echo "  2. kind load docker-image rag-service:v1 --name dojo"
echo "  3. kubectl create namespace dojo-genai --dry-run=client -o yaml | kubectl apply -f -"
echo "  4. kubectl apply -f $WORK/k8s/"
echo "  5. kubectl rollout status deployment/rag-service -n dojo-genai"
echo
echo "Prerequisites  : Docker running, kind cluster named 'dojo', kubectl context kind-dojo"
echo
echo "Verify + flag  : bash courses/course-11-generative-ai/challenges/$SLUG/verify.sh"
