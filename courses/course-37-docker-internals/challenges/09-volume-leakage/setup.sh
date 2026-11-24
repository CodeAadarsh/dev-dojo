#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="dojo-docker-volume"

echo "==> Setting up challenge: Volume Leakage"

# Idempotent namespace
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Deploy counter app with NO volume (writes to container layer)
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: counter
  namespace: dojo-docker-volume
  annotations:
    dojo.docker/has-volume: "false"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: counter
  template:
    metadata:
      labels:
        app: counter
    spec:
      containers:
      - name: counter
        image: busybox:1.36
        command:
        - sh
        - -c
        - |
          COUNT=$(cat /data/count.txt 2>/dev/null || echo 0)
          COUNT=$((COUNT + 1))
          echo $COUNT > /data/count.txt
          echo "Count: $COUNT"
          sleep 30
EOF

echo ""
echo "==> Scenario planted."
echo ""
echo "    Namespace : dojo-docker-volume"
echo "    Deployment: counter"
echo "    Problem   : /data/count.txt lives in the container's ephemeral writable layer."
echo "                Every restart resets the counter to 0."
echo ""
echo "    Your job  : Mount a Volume at /data so writes survive container restarts."
echo "    Hint      : An emptyDir volume is sufficient."
echo ""
echo "    When done : bash courses/course-37-docker-internals/challenges/09-volume-leakage/verify.sh"
