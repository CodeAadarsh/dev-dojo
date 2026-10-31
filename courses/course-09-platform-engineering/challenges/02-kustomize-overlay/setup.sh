#!/usr/bin/env bash
# Plants the "Kustomize Overlay for Production" scenario.
# Creates namespace dojo-kustomize. The learner builds the base + overlay outside
# the kube-dojo tree and applies it with kubectl apply -k.
set -euo pipefail

NS=dojo-kustomize

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Targeting your current context anyway."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

echo
echo "✓ Namespace '$NS' ready."
echo
echo "Build your Kustomize layout outside this repo (e.g. /tmp/kustomize-lab/):"
echo "  base/"
echo "    kustomization.yaml"
echo "    deployment.yaml        # Deployment 'web', ns dojo-kustomize, nginx:1.27-alpine, 1 replica"
echo "  overlays/prod/"
echo "    kustomization.yaml     # references ../../base, adds commonLabels env: prod"
echo "    replica-patch.yaml     # strategic-merge: spec.replicas: 3"
echo
echo "Then: kubectl apply -k overlays/prod/"
echo "Then: bash courses/course-09-platform-engineering/challenges/02-kustomize-overlay/verify.sh"
