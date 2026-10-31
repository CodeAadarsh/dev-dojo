#!/usr/bin/env bash
# Plants the "Restricted By Default" scenario: an over-permissive legacy-app
# Deployment (root, all caps, no seccomp) in an UNLABELLED namespace, so the API
# server admits it. The learner enables PSA enforce=restricted on the namespace
# AND rebuilds the workload to comply. Idempotent; never strips a label the
# learner adds later (apply only tracks fields it set).
set -euo pipefail

NS=dojo-hardpsa

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Targeting your current context anyway."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

cat <<'YAML' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: legacy-app
  namespace: dojo-hardpsa
  labels:
    app: legacy-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: legacy-app
  template:
    metadata:
      labels:
        app: legacy-app
    spec:
      securityContext:
        runAsUser: 0                 # root — violates restricted
      containers:
        - name: app
          image: busybox:1.36
          command: ["sh", "-c", "sleep 3600"]
          securityContext:
            allowPrivilegeEscalation: true   # violates restricted
            capabilities:
              add: ["NET_ADMIN"]             # extra cap — violates restricted
          # no seccompProfile -> Unconfined  # violates restricted
YAML

kubectl -n "$NS" rollout status deploy/legacy-app --timeout=60s >/dev/null 2>&1 || true

echo
echo "✓ Scenario deployed to namespace '$NS'."
echo "  Planted (over-permissive — admitted because the namespace has no PSA label):"
echo "    - Deployment 'legacy-app' (busybox:1.36) running as root (runAsUser 0),"
echo "      allowPrivilegeEscalation=true, capabilities add NET_ADMIN, seccomp Unconfined."
echo
echo "  Current namespace Pod Security labels (expect none yet):"
kubectl get ns "$NS" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>/dev/null \
  | sed 's/^$/    (no enforce label)/'
echo
echo "  Next: label the namespace pod-security.kubernetes.io/enforce=restricted"
echo "  AND rebuild the workload to comply, then run verify.sh."
