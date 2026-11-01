#!/usr/bin/env bash
# Plants the skeleton manifests for "Safe Node-Pool Upgrade".
# Idempotent — skeletons are not overwritten if they already exist.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/06-safe-upgrade"
mkdir -p "$WORK"

if [ ! -f "$WORK/deployment.yaml" ]; then
cat > "$WORK/deployment.yaml" << 'YAMLEOF'
# checkout-api Deployment skeleton.
# Task 1: add a readinessProbe on containers[0].
# Task 2: set strategy.rollingUpdate.maxUnavailable to 0.
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: checkout-api
  namespace: dojo-checkout
  labels:
    app: checkout
    version: "1.0"
spec:
  replicas: 3
  selector:
    matchLabels:
      app: checkout
  strategy:
    type: RollingUpdate
    rollingUpdate:
      # TODO: set to 0 (zero-downtime: new pod must be Ready before old pod is terminated)
      maxUnavailable: 1
      # surge allows one extra pod during rollout; keep at 1 so there's room to add before removing
      maxSurge: 1
  template:
    metadata:
      labels:
        app: checkout
        version: "1.0"
    spec:
      terminationGracePeriodSeconds: 30
      containers:
        - name: checkout-api
          image: nginx:1.27-alpine
          ports:
            - name: http
              containerPort: 8080
          # TODO: add a readinessProbe here.
          # The container serves on port 8080 at path /healthz.
          # Use httpGet. Without a readiness probe, Kubernetes sends traffic
          # to the pod immediately after it starts, before the app is warm.
          resources:
            requests:
              cpu: 200m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 512Mi
YAMLEOF
fi

if [ ! -f "$WORK/pdb.yaml" ]; then
cat > "$WORK/pdb.yaml" << 'YAMLEOF'
# PodDisruptionBudget for checkout-api.
# Task 1: set spec.minAvailable to an integer >= 1 (e.g. 2 for a 3-replica Deployment).
# Task 2: ensure spec.selector.matchLabels matches the pod template labels in deployment.yaml.
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: checkout-api-pdb
  namespace: dojo-checkout
spec:
  # TODO: set minAvailable to an integer >= 1
  # This is the minimum number of pods that must be running during a voluntary disruption.
  # For a 3-replica Deployment, minAvailable: 2 means at most 1 pod can be evicted at a time.
  minAvailable: 0
  selector:
    matchLabels:
      # TODO: these labels must match the pod template labels in deployment.yaml exactly.
      # A mismatched selector means the PDB matches zero pods and provides no protection.
      app: ""
YAMLEOF
fi

echo
echo "Work directory : $WORK"
echo
echo "Files:"
echo "  deployment.yaml  — fix maxUnavailable and add readinessProbe"
echo "  pdb.yaml         — fix minAvailable and ensure selector matches Deployment labels"
echo
echo "When done, verify:"
echo "  bash courses/course-34-managed-kubernetes/challenges/06-safe-upgrade/verify.sh"
