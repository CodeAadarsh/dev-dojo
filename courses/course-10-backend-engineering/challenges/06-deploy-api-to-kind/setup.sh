#!/usr/bin/env bash
# Plants the deploy-api-to-kind challenge: Flask app, Dockerfile, and a starter manifest.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/06-deploy-api-to-kind"
mkdir -p "$WORK"

# --- Flask app ---
cat > "$WORK/app.py" << 'PYEOF'
from flask import Flask, jsonify

app = Flask(__name__)


@app.route("/healthz")
def healthz():
    return jsonify({"status": "ok"})


@app.route("/")
def index():
    return jsonify({"service": "dojo-api", "version": "1.0"})


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
PYEOF

# --- requirements.txt ---
cat > "$WORK/requirements.txt" << 'EOF'
flask==3.0.3
EOF

# --- Dockerfile ---
cat > "$WORK/Dockerfile" << 'EOF'
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .
EXPOSE 5000
CMD ["python", "app.py"]
EOF

# --- starter manifest (learner fills in the image tag) ---
cat > "$WORK/deploy.yaml" << 'EOF'
# Fill in every FILL_IN, then: kubectl apply -f deploy.yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: dojo-backend
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dojo-api
  namespace: dojo-backend
  labels:
    app: dojo-api
spec:
  replicas: 1
  selector:
    matchLabels:
      app: dojo-api
  template:
    metadata:
      labels:
        app: dojo-api
    spec:
      containers:
        - name: api
          image: FILL_IN          # replace with the tag you built: dojo-api:v1
          imagePullPolicy: IfNotPresent   # required for kind-loaded images
          ports:
            - containerPort: 5000
          readinessProbe:
            httpGet:
              path: /healthz
              port: 5000
            initialDelaySeconds: 3
            periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: dojo-api
  namespace: dojo-backend
spec:
  selector:
    app: dojo-api
  ports:
    - port: 80
      targetPort: 5000
EOF

echo
echo "Work directory: $WORK"
echo
echo "Files written:"
echo "  app.py           — Flask API (GET /healthz, GET /)"
echo "  requirements.txt — flask==3.0.3"
echo "  Dockerfile       — python:3.12-slim, binds on 0.0.0.0:5000"
echo "  deploy.yaml      — starter Deployment + Service; fill in the image tag"
echo
echo "Task:"
echo "  1. Edit $WORK/deploy.yaml — replace FILL_IN with: dojo-api:v1"
echo "  2. Apply the manifest: kubectl apply -f $WORK/deploy.yaml"
echo "  3. Run the verifier (it builds the image and loads it into kind):"
echo "     bash courses/course-10-backend-engineering/challenges/06-deploy-api-to-kind/verify.sh"
echo
echo "Prereqs: Docker Desktop running + kind cluster 'dojo'"
echo "  Create cluster if needed: kind create cluster --name dojo"
