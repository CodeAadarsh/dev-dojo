#!/usr/bin/env bash
# Plants the "Autoscale Under Load" scenario: a Deployment WITH cpu requests
# but no HorizontalPodAutoscaler — scaling is still a manual pager.
set -euo pipefail

NS=dojo-hpa

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
  namespace: dojo-hpa
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
      containers:
        - name: web
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: 100m          # the HPA's denominator for CPU utilization
              memory: 32Mi
            limits:
              cpu: 250m
              memory: 64Mi
YAML

echo
echo "✓ Scenario deployed to namespace '$NS'."
echo "  Deployment 'web' (nginx:1.27-alpine) has cpu requests (100m) but NO autoscaler."
echo "  Scaling is still manual toil. Create an autoscaling/v2 HPA targeting 'web' on"
echo "  CPU utilization (~50%), minReplicas 2, maxReplicas 5, then run verify.sh."
echo
echo "  Note: live scaling needs metrics-server ('kubectl top pods -n $NS'). The"
echo "        verifier checks the HPA spec, so you don't need it to earn the flag."
