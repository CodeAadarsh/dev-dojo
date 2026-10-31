#!/usr/bin/env bash
# Plants the "Drain Gracefully" scenario: a Deployment that resets live
# connections on termination — no preStop hook, no readinessProbe, and the
# default grace period. Every rollout/scale-down races endpoint removal.
set -euo pipefail

NS=dojo-grace

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Targeting your current context anyway."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

cat <<'YAML' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: dojo-grace
  labels:
    app: web
spec:
  replicas: 2
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      # No preStop hook and the default 30s grace period: on termination the
      # container gets SIGTERM immediately, in parallel with endpoint removal.
      # No readinessProbe: pods are routed to the moment the container starts.
      containers:
        - name: web
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: 25m
              memory: 32Mi
            limits:
              cpu: 100m
              memory: 64Mi
YAML

# A Service so the connection-reset symptom is observable end to end.
cat <<'YAML' | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: web
  namespace: dojo-grace
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
echo "✓ Scenario deployed to namespace '$NS'."
echo "  Deployment 'web' (nginx:1.27-alpine, 2 replicas) terminates HARD:"
echo "    - no lifecycle.preStop hook  -> SIGTERM races endpoint removal"
echo "    - no readinessProbe          -> traffic routed before/after readiness is uncontrolled"
echo "    - default terminationGracePeriodSeconds (30)"
echo "  Service 'web' fronts it so you can watch connections reset during a rollout."
echo
echo "  Add a preStop drain + a grace period that covers it + a readinessProbe,"
echo "  then run verify.sh."
