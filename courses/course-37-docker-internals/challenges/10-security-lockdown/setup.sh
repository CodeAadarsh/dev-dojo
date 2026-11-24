#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="dojo-docker-security"

echo "==> Setting up challenge: Security Lockdown"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Deploy nginx with NO security hardening (the insecure baseline)
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app
  namespace: dojo-docker-security
  annotations:
    dojo.docker/security-level: "none"
spec:
  replicas: 1
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
EOF

echo ""
echo "==> Scenario planted."
echo ""
echo "    Namespace : dojo-docker-security"
echo "    Deployment: app (nginx:1.27-alpine)"
echo "    State     : Running as root, full capabilities, writable filesystem"
echo ""
echo "    Your job  : Apply all four CIS hardening measures:"
echo "                1. runAsNonRoot: true  (pod-level securityContext)"
echo "                2. allowPrivilegeEscalation: false  (container securityContext)"
echo "                3. readOnlyRootFilesystem: true  (container securityContext)"
echo "                4. capabilities.drop: [ALL]  (container securityContext)"
echo ""
echo "    TIP: nginx needs writable /var/cache/nginx and /var/run — add emptyDir volumes."
echo ""
echo "    When done : bash courses/course-37-docker-internals/challenges/10-security-lockdown/verify.sh"
