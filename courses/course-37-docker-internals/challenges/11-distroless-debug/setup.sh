#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="dojo-docker-distroless"

echo "==> Setting up challenge: Distroless Debug"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Bad config — wrong-host causes the app to exit 1
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
  namespace: dojo-docker-distroless
data:
  DATABASE_URL: "postgresql://wrong-host:5432/db"
EOF

# Deployment that simulates a distroless app crashlooping on bad config
# Using alpine as a stand-in (alpine:3.20 behaves the same way for this lab)
# The app: check DATABASE_URL, exit 1 if it contains "wrong-host"
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
  namespace: dojo-docker-distroless
  annotations:
    dojo.docker/image-type: "distroless-simulation"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: api
  template:
    metadata:
      labels:
        app: api
    spec:
      containers:
      - name: api
        image: alpine:3.20
        command:
        - sh
        - -c
        - |
          echo "Starting api..."
          if echo "$DATABASE_URL" | grep -q "wrong-host"; then
            echo "ERROR: Cannot connect to database at $DATABASE_URL" >&2
            exit 1
          fi
          echo "Connected to $DATABASE_URL"
          sleep 3600
        env:
        - name: DATABASE_URL
          valueFrom:
            configMapKeyRef:
              name: app-config
              key: DATABASE_URL
EOF

echo ""
echo "==> Scenario planted."
echo ""
echo "    Namespace : dojo-docker-distroless"
echo "    Deployment: api (crashlooping — bad DATABASE_URL)"
echo "    ConfigMap : app-config (contains the bad value)"
echo ""
echo "    Your job  : Use kubectl debug to inspect the container env,"
echo "                identify the bad DATABASE_URL, fix the ConfigMap,"
echo "                then rollout restart."
echo ""
echo "    Debug cmd : kubectl debug -it -n dojo-docker-distroless \\"
echo "                  \$(kubectl get pod -n dojo-docker-distroless -l app=api -o jsonpath='{.items[0].metadata.name}') \\"
echo "                  --image=busybox:1.36 --target=api"
echo ""
echo "    When done : bash courses/course-37-docker-internals/challenges/11-distroless-debug/verify.sh"
