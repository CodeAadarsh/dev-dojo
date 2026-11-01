#!/usr/bin/env bash
# Plants the stable Deployment + Service for the canary rollout challenge,
# then places a canary.yaml stub in the work directory.
# Idempotent — uses kubectl apply throughout.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/05-canary-rollout"
NS="dojo-cicd"

# Warn (don't fail) if not on the dojo context
CURRENT_CTX=$(kubectl config current-context 2>/dev/null || echo "unknown")
[ "$CURRENT_CTX" = "kind-dojo" ] \
  || echo "WARNING: current kubectl context is '$CURRENT_CTX', not 'kind-dojo'. Run: kubectl config use-context kind-dojo"

mkdir -p "$WORK"

# ── Namespace ────────────────────────────────────────────────────────────────
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

# ── Stable Deployment ────────────────────────────────────────────────────────
kubectl apply -f - << 'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dojo-web-stable
  namespace: dojo-cicd
  labels:
    app: dojo-web
    track: stable
spec:
  replicas: 3
  selector:
    matchLabels:
      app: dojo-web
      track: stable
  template:
    metadata:
      labels:
        app: dojo-web
        track: stable
        version: v1.0.0
    spec:
      containers:
      - name: web
        image: nginx:1.27-alpine
        ports:
        - containerPort: 80
        resources:
          requests:
            cpu: 10m
            memory: 16Mi
          limits:
            memory: 32Mi
YAML

# ── Service (selects app=dojo-web — hits both stable and canary pods) ────────
kubectl apply -f - << 'YAML'
apiVersion: v1
kind: Service
metadata:
  name: dojo-web
  namespace: dojo-cicd
spec:
  selector:
    app: dojo-web
  ports:
  - port: 80
    targetPort: 80
YAML

# ── canary.yaml stub (only written if not already present) ───────────────────
if [ ! -f "$WORK/canary.yaml" ]; then
  cat > "$WORK/canary.yaml" << 'YAMEOF'
# canary.yaml — complete this Deployment and apply it with:
#   kubectl apply -f ~/.kube-dojo-work/05-canary-rollout/canary.yaml
#
# Requirements:
#   - namespace: dojo-cicd
#   - pod template labels must include: app: dojo-web  AND  track: canary
#   - spec.selector.matchLabels must include: track: canary
#   - replicas: 1  (25% traffic: 1 canary / 4 total endpoints)
#   - image: nginx:1.27-alpine
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dojo-web-canary
  namespace: dojo-cicd
  labels:
    app: dojo-web
    track: canary
spec:
  replicas: 1
  selector:
    matchLabels:
      app: dojo-web
      track: canary   # <-- keeps canary selector isolated from stable
  template:
    metadata:
      labels:
        app: dojo-web  # <-- shared label: Service selects this
        track: canary
        version: v1.1.0
    spec:
      containers:
      - name: web
        image: nginx:1.27-alpine  # TODO: swap to your new image tag
        ports:
        - containerPort: 80
        resources:
          requests:
            cpu: 10m
            memory: 16Mi
          limits:
            memory: 32Mi
YAMEOF
fi

echo
echo "Namespace      : $NS (stable Deployment + dojo-web Service applied)"
echo "Work directory : $WORK"
echo
echo "Stable pods:"
kubectl -n "$NS" get pods -l track=stable --no-headers 2>/dev/null | head -5 || true
echo
echo "Task           : complete $WORK/canary.yaml and apply it:"
echo "                 kubectl apply -f $WORK/canary.yaml"
echo
echo "Verify + flag  : bash courses/course-25-cicd/challenges/05-canary-rollout/verify.sh"
