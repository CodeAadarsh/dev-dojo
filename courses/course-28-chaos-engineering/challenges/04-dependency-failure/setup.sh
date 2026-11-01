#!/usr/bin/env bash
# Plants the "Dependency Failure" scenario: a backend + a frontend app whose
# readinessProbe calls the backend — the anti-pattern that causes cascading NotReady.
# Idempotent: re-running is safe.
set -euo pipefail

NS=dojo-chaos-dep

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "WARNING: current kube-context is not 'kind-dojo'. Proceeding with current context anyway."
  echo "         Run: kubectl config use-context kind-dojo"
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

# ── backend Deployment + Service ────────────────────────────────────────────
cat <<'YAML' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
  namespace: dojo-chaos-dep
  labels:
    app: backend
spec:
  replicas: 2
  selector:
    matchLabels:
      app: backend
  template:
    metadata:
      labels:
        app: backend
    spec:
      containers:
        - name: backend
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: 30m
              memory: 16Mi
            limits:
              cpu: 100m
              memory: 32Mi
---
apiVersion: v1
kind: Service
metadata:
  name: backend-svc
  namespace: dojo-chaos-dep
spec:
  selector:
    app: backend
  ports:
    - port: 80
      targetPort: 80
YAML

# ── app Deployment + Service — BROKEN: probe calls backend-svc ───────────
# This is the anti-pattern to fix. The readinessProbe runs wget against
# backend-svc. When backend is unavailable, app pods go NotReady even though
# the app container itself is perfectly healthy.
cat <<'YAML' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app
  namespace: dojo-chaos-dep
  labels:
    app: app
spec:
  replicas: 2
  selector:
    matchLabels:
      app: app
  template:
    metadata:
      labels:
        app: app
    spec:
      containers:
        - name: app
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
          readinessProbe:
            exec:
              command:
                - sh
                - -c
                - "wget -q -O /dev/null http://backend-svc/ || exit 1"
            initialDelaySeconds: 5
            periodSeconds: 5
            failureThreshold: 2
            timeoutSeconds: 3
---
apiVersion: v1
kind: Service
metadata:
  name: app-svc
  namespace: dojo-chaos-dep
spec:
  selector:
    app: app
  ports:
    - port: 80
      targetPort: 80
YAML

echo
echo "Scenario deployed to namespace '$NS'."
echo
echo "  backend (2 replicas) : nginx:1.27-alpine behind Service backend-svc"
echo "  app     (2 replicas) : nginx:1.27-alpine — readinessProbe calls backend-svc (broken!)"
echo
echo "Next steps:"
echo "  1. Wait ~15s for pods to become Ready:"
echo "       kubectl -n $NS get pods -w"
echo "  2. Inspect the broken probe:"
echo "       kubectl -n $NS get deploy app -o jsonpath='{.spec.template.spec.containers[0].readinessProbe}' && echo"
echo "  3. Fix the app Deployment so its probe checks the app's OWN health."
echo "  4. Add resource requests (cpu + memory) to the app container."
echo "  5. Run the verifier:"
echo "       bash courses/course-28-chaos-engineering/challenges/04-dependency-failure/verify.sh"
