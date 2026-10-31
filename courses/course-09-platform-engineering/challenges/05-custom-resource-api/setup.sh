#!/usr/bin/env bash
# Plants the "Custom Resource API" scenario: creates the target namespace.
# The learner must define the CRD and create the CR themselves.
set -euo pipefail

NS=dojo-crd2

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Targeting your current context anyway."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

echo
echo "✓ Namespace '$NS' ready."
echo
echo "Your task:"
echo "  1. Define and apply a CRD: group=platform.dojo, kind=Environment,"
echo "     scope=Namespaced, spec.tier required enum [dev stage prod]."
echo "  2. Wait for the CRD to reach Established status."
echo "  3. Create an Environment CR in namespace '$NS' with a valid spec.tier."
echo "Run verify.sh when done."
