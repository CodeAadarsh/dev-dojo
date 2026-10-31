#!/usr/bin/env bash
# Plants the "Ship It: Gunicorn + Docker + k8s" challenge into the work directory.
# Idempotent — re-running overwrites files.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/06-dockerize-and-deploy"
mkdir -p "$WORK"

if ! kubectl config current-context 2>/dev/null | grep -q 'kind-dojo'; then
    echo "Warning: current context is not kind-dojo — make sure Docker and kind are running."
    echo "  kind create cluster --name dojo"
fi

# ── app.py ────────────────────────────────────────────────────────────────────
cat > "$WORK/app.py" << 'PYEOF'
from flask import Flask, jsonify


def create_app():
    app = Flask(__name__)

    @app.route('/health')
    def health():
        return jsonify({'status': 'ok'}), 200

    @app.route('/')
    def index():
        return jsonify({'message': 'flask-app running on gunicorn'}), 200

    return app


app = create_app()
PYEOF

# ── requirements.txt ─────────────────────────────────────────────────────────
cat > "$WORK/requirements.txt" << 'EOF'
flask==3.1.1
gunicorn==22.0.0
EOF

# ── Dockerfile ───────────────────────────────────────────────────────────────
cat > "$WORK/Dockerfile" << 'DEOF'
FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

EXPOSE 8000

CMD ["gunicorn", "-w", "2", "-b", "0.0.0.0:8000", "app:create_app()"]
DEOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : build the image, load it into kind, then deploy to dojo-flask."
echo
echo "Steps:"
echo "  1. cd $WORK"
echo "  2. docker build -t flask-app:dojo ."
echo "  3. kind load docker-image flask-app:dojo --name dojo"
echo "  4. kubectl create namespace dojo-flask --dry-run=client -o yaml | kubectl apply -f -"
echo "  5. Write + apply a Deployment and Service manifest (see brief.md for spec)"
echo
echo "Requirements:"
echo "  - Namespace:        dojo-flask"
echo "  - Image:            flask-app:dojo  (imagePullPolicy: Never)"
echo "  - Gunicorn command: gunicorn -w 2 -b 0.0.0.0:8000 'app:create_app()'"
echo "  - readinessProbe:   httpGet /health port 8000"
echo "  - Service:          ClusterIP port 80 -> 8000"
echo
echo "Verify + flag  : bash courses/course-12-flask-production/challenges/06-dockerize-and-deploy/verify.sh"
