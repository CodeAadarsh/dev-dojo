#!/usr/bin/env bash
# Plants the "Page at 3am" incident: a Deployment whose containers run fine but
# never pass readiness because the readinessProbe points at the WRONG PORT.
# Result: pods Running, logs clean, 0/1 Ready, Service has zero endpoints,
# every request 503s. A realistic "green deploy, dark service" SRE incident.
set -euo pipefail

NS=dojo-incident

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Targeting your current context anyway."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

# nginx listens on 80, but the readinessProbe checks 8080 -> always fails ->
# pods never Ready -> never added to Service endpoints. The container is healthy;
# the probe config lies about which port the app serves on.
cat <<'YAML' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: dojo-incident
  labels:
    app: web
spec:
  replicas: 3
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
        - name: web
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
          readinessProbe:
            httpGet:
              path: /
              port: 8080      # BUG: nginx serves on 80, not 8080 -> probe never passes
            initialDelaySeconds: 2
            periodSeconds: 5
            failureThreshold: 3
          resources:
            requests:
              cpu: 25m
              memory: 32Mi
            limits:
              cpu: 100m
              memory: 64Mi
YAML

cat <<'YAML' | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: web
  namespace: dojo-incident
  labels:
    app: web
spec:
  selector:
    app: web
  ports:
    - name: http
      port: 80
      targetPort: 80
YAML

echo
echo "✓ Incident planted in namespace '$NS'."
echo "  Deployment 'web' (nginx:1.27-alpine, 3 replicas): pods will come up Running"
echo "  with CLEAN logs, but every pod stays 0/1 Ready and the 'web' Service has"
echo "  ZERO endpoints. The page is firing. Triage it (see brief.md), fix the root"
echo "  cause in the Deployment, then run verify.sh."
