#!/usr/bin/env bash
# Plants the "Crossplane: Author an XRD, Composition & Claim" scenario.
# Creates the target namespace and validates prerequisites.
set -euo pipefail

NS=dojo-crossplane

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Targeting your current context anyway."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

# Warn if Crossplane CRDs are not installed
if ! kubectl get crd compositeresourcedefinitions.apiextensions.crossplane.io >/dev/null 2>&1; then
  echo "⚠  Crossplane CRDs not found. Install Crossplane before running this challenge:"
  echo "   helm repo add crossplane-stable https://charts.crossplane.io/stable"
  echo "   helm install crossplane crossplane-stable/crossplane --namespace crossplane-system --create-namespace --version 1.15.0 --wait"
  echo "   Then install provider-nop as described in brief.md."
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

echo
echo "✓ Namespace '$NS' ready."
echo
echo "Your task:"
echo "  1. Install Crossplane + provider-nop (see brief.md)."
echo "  2. Author and apply an XRD: metadata.name=xobjectstores.platform.dojo"
echo "  3. Author and apply a Composition: name=objectstore-nop.platform.dojo"
echo "  4. Wait for the XRD to be Established:"
echo "     kubectl wait --for=condition=Established xrd/xobjectstores.platform.dojo --timeout=60s"
echo "  5. Apply a Claim: kind=ObjectStore, name=my-store, namespace=$NS"
echo "  6. Run verify.sh when done."
