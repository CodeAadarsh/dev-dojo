#!/usr/bin/env bash
# Plants the "Deploy Model to kind" starter project.
# Idempotent — re-running overwrites source files.
set -euo pipefail

SLUG="06-deploy-model-to-kind"
WORK="$HOME/.kube-dojo-work/$SLUG"
mkdir -p "$WORK/app" "$WORK/k8s"

# ── train & serialize the model artifact ────────────────────────────────────
python3 - << 'PYEOF'
import pickle, os, sys
try:
    from sklearn.datasets import load_iris
    from sklearn.linear_model import LogisticRegression
except ImportError:
    print("ERROR: scikit-learn not installed. Run: pip install scikit-learn")
    sys.exit(1)

work = os.path.expanduser("~/.kube-dojo-work/06-deploy-model-to-kind/app")
out  = os.path.join(work, "model.pkl")
iris = load_iris()
clf  = LogisticRegression(random_state=42, max_iter=200)
clf.fit(iris.data, iris.target)
with open(out, "wb") as f:
    pickle.dump(clf, f)
print(f"model artifact written to {out}")
PYEOF

# ── app/main.py — fully implemented ─────────────────────────────────────────
cat > "$WORK/app/main.py" << 'PYEOF'
# main.py — fully implemented model server. Do not modify.
import os, pickle
from contextlib import asynccontextmanager
from typing import List
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, field_validator
import numpy as np

MODEL_PATH    = os.path.join(os.path.dirname(__file__), "model.pkl")
MODEL_VERSION = "1.0.0"
_model        = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    global _model
    with open(MODEL_PATH, "rb") as f:
        _model = pickle.load(f)
    yield


app = FastAPI(lifespan=lifespan)


class PredictRequest(BaseModel):
    features: List[float]

    @field_validator("features")
    @classmethod
    def must_be_four(cls, v):
        if len(v) != 4:
            raise ValueError("features must have exactly 4 elements")
        return v


class PredictResponse(BaseModel):
    prediction: int
    model_version: str


@app.get("/healthz")
def healthz():
    if _model is None:
        raise HTTPException(status_code=503, detail="model not loaded")
    return {"status": "ok"}


@app.post("/predict", response_model=PredictResponse)
def predict(req: PredictRequest):
    if _model is None:
        raise HTTPException(status_code=503, detail="model not loaded")
    pred = int(_model.predict([req.features])[0])
    return PredictResponse(prediction=pred, model_version=MODEL_VERSION)
PYEOF

# ── app/requirements.txt ─────────────────────────────────────────────────────
cat > "$WORK/app/requirements.txt" << 'PYEOF'
fastapi==0.115.0
uvicorn[standard]==0.30.6
scikit-learn==1.5.2
numpy==1.26.4
pydantic==2.9.2
PYEOF

# ── app/Dockerfile skeleton ───────────────────────────────────────────────────
cat > "$WORK/app/Dockerfile" << 'PYEOF'
# Dockerfile — complete this skeleton.
# Requirements:
#   - Base image: python:3.11-slim
#   - Install deps from requirements.txt BEFORE copying source (layer-cache friendly)
#   - Run uvicorn on 0.0.0.0:8080
#
# TODO: fill in the blanks (lines marked with <FILL IN>)

FROM <FILL IN>
WORKDIR /app
COPY requirements.txt .
RUN <FILL IN>
COPY . .
EXPOSE 8080
CMD <FILL IN>
PYEOF

# ── k8s/deployment.yaml skeleton ─────────────────────────────────────────────
cat > "$WORK/k8s/deployment.yaml" << 'PYEOF'
# deployment.yaml — complete this skeleton.
# Requirements:
#   namespace: dojo-mlops
#   image: dojo-model-server:v1
#   imagePullPolicy: IfNotPresent
#   containerPort: 8080
#   readinessProbe: HTTP GET /healthz port 8080, initialDelaySeconds: 5
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
          image: # FILL IN: dojo-model-server:v1
          imagePullPolicy: # FILL IN: IfNotPresent
          ports:
            - containerPort: # FILL IN: 8080
          readinessProbe:
            httpGet:
              path: # FILL IN: /healthz
              port: # FILL IN: 8080
            initialDelaySeconds: # FILL IN: 5
            periodSeconds: 10
PYEOF

# ── k8s/service.yaml skeleton ────────────────────────────────────────────────
cat > "$WORK/k8s/service.yaml" << 'PYEOF'
# service.yaml — complete this skeleton.
# Requirements: ClusterIP pointing at containerPort 8080 in dojo-mlops.
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
      targetPort: # FILL IN: 8080
  type: ClusterIP
PYEOF

echo
echo "Work directory : $WORK"
echo
echo "Task           :"
echo "  1. Complete app/Dockerfile (base image, pip install, CMD)"
echo "  2. Build:  docker build -t dojo-model-server:v1 $WORK/app/"
echo "  3. Load:   kind load docker-image dojo-model-server:v1 --name dojo"
echo "  4. Create ns: kubectl create ns dojo-mlops --dry-run=client -o yaml | kubectl apply -f -"
echo "  5. Complete k8s/deployment.yaml (image, imagePullPolicy, port, readinessProbe)"
echo "  6. Complete k8s/service.yaml (targetPort)"
echo "  7. Apply:  kubectl apply -f $WORK/k8s/"
echo "  8. Wait:   kubectl -n dojo-mlops rollout status deployment/model-server"
echo
echo "Prereqs        : Docker + kind cluster named 'dojo' + kubectl context kind-dojo"
echo "Verify + flag  : bash courses/course-24-mlops/challenges/06-deploy-model-to-kind/verify.sh"
