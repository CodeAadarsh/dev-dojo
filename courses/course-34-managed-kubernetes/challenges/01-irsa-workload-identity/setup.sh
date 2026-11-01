#!/usr/bin/env bash
# Setup for "IRSA / Workload Identity — Scoped Pod Access".
# Plants stub manifests in the learner's work directory.
set -euo pipefail

SLUG="01-irsa-workload-identity"
WORK="$HOME/.kube-dojo-work/$SLUG"

CURRENT_CTX=$(kubectl config current-context 2>/dev/null || echo "none")
if [ "$CURRENT_CTX" != "kind-dojo" ]; then
  echo "⚠ Warning: current context is '$CURRENT_CTX', not 'kind-dojo'."
  echo "  This challenge authors cloud manifests — no cluster access needed, but be aware."
fi

mkdir -p "$WORK"

cat > "$WORK/serviceaccount.yaml" << 'EOF'
# Challenge: complete this ServiceAccount for IRSA (EKS) or Workload Identity (GKE).
# Requirements:
#   1. name must NOT be 'default'
#   2. Add ONE of these annotations:
#        eks.amazonaws.com/role-arn: arn:aws:iam::<account-id>:role/<role-name>
#        iam.gke.io/gcp-service-account: <sa-name>@<project>.iam.gserviceaccount.com
apiVersion: v1
kind: ServiceAccount
metadata:
  name: TODO-change-me
  namespace: prod
  annotations:
    # TODO: add the IRSA or Workload Identity annotation here
EOF

cat > "$WORK/deployment.yaml" << 'EOF'
# Challenge: bind your ServiceAccount to this Deployment.
# Requirements:
#   1. spec.template.spec.serviceAccountName must match the SA name in serviceaccount.yaml
#   2. Must NOT be 'default'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ml-trainer
  namespace: prod
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ml-trainer
  template:
    metadata:
      labels:
        app: ml-trainer
    spec:
      # TODO: set serviceAccountName to the name of your ServiceAccount
      containers:
        - name: trainer
          image: python:3.12-slim
          command: ["python3", "-c", "import time; time.sleep(3600)"]
          resources:
            requests:
              cpu: "100m"
              memory: "128Mi"
            limits:
              cpu: "500m"
              memory: "512Mi"
EOF

echo "Work directory ready: $WORK"
echo ""
echo "Files planted:"
echo "  $WORK/serviceaccount.yaml  (stub — add IRSA/WI annotation, fix the name)"
echo "  $WORK/deployment.yaml      (stub — set serviceAccountName)"
echo ""
echo "Next: edit both files, then run the verifier:"
echo "  bash courses/course-34-managed-kubernetes/challenges/01-irsa-workload-identity/verify.sh"
