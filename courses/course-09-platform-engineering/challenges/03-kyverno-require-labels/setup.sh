#!/usr/bin/env bash
# Plants the "Kyverno: Require Pod Labels" scenario.
# Creates the target namespace and a pre-existing unlabelled pod (to show the 'before' state).
set -euo pipefail

NS=dojo-policy

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Targeting your current context anyway."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

# Warn if Kyverno is not installed
if ! kubectl get ns kyverno >/dev/null 2>&1; then
  echo "⚠  Kyverno namespace not found. Install Kyverno before running this challenge:"
  echo "   helm repo add kyverno https://kyverno.github.io/kyverno/"
  echo "   helm install kyverno kyverno/kyverno --namespace kyverno --create-namespace --version 3.2.6 --set admissionController.replicas=1"
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

# Plant a well-labelled deployment to show the target state
cat <<'YAML' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: labelled-app
  namespace: dojo-policy
  labels:
    app: labelled-app
    team: platform
spec:
  replicas: 1
  selector:
    matchLabels:
      app: labelled-app
      team: platform
  template:
    metadata:
      labels:
        app: labelled-app
        team: platform
    spec:
      containers:
        - name: app
          image: nginx:1.27-alpine
          resources:
            requests:
              cpu: 10m
              memory: 16Mi
YAML

echo
echo "✓ Namespace '$NS' ready."
echo "✓ Deployment 'labelled-app' created — it has both required labels and will pass policy."
echo
echo "Your task:"
echo "  1. Install Kyverno (if not already installed — see brief.md)."
echo "  2. Author a ClusterPolicy 'require-pod-labels' in Enforce mode."
echo "  3. Test: 'kubectl -n dojo-policy run bad --image=nginx:1.27-alpine' should be denied."
echo "  4. Test: 'kubectl -n dojo-policy run good --image=nginx:1.27-alpine --labels=app=web,team=alpha' should succeed."
echo "  5. Run verify.sh when done."
