#!/usr/bin/env bash
# Plants the "Lock the Namespace" scenario: a privileged, root, no-seccomp
# workload in a namespace with NO Pod Security Admission labels.
set -euo pipefail

NS=dojo-psa

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Targeting your current context anyway."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

# Create the namespace WITHOUT any pod-security labels — that's the vulnerability.
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

# Scrub any pod-security labels left over from a previous run so the privileged
# pod below is always admitted on a re-run (idempotent reset of the scenario).
kubectl label ns "$NS" \
  pod-security.kubernetes.io/enforce- \
  pod-security.kubernetes.io/enforce-version- \
  pod-security.kubernetes.io/warn- \
  pod-security.kubernetes.io/warn-version- \
  pod-security.kubernetes.io/audit- \
  pod-security.kubernetes.io/audit-version- >/dev/null 2>&1 || true

cat <<'YAML' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
  namespace: dojo-psa
  labels:
    app: api
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
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
          securityContext:
            privileged: true            # full node access — the finding
            runAsUser: 0                 # explicitly root
            allowPrivilegeEscalation: true
YAML

echo
echo "✓ Scenario deployed to namespace '$NS'."
echo "  Deployment 'api' runs PRIVILEGED, as root, with no seccomp profile, and the"
echo "  namespace has NO pod-security labels — nothing stops it."
echo
echo "  Next: enforce the 'restricted' Pod Security Standard on the namespace AND"
echo "        refactor 'api' until a compliant pod is Running, then run verify.sh."
