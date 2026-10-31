#!/usr/bin/env bash
# "Teach the API a New Word" — prepares the namespace. You define the CRD and
# create the Widget yourself (that IS the challenge).
set -euo pipefail

NS=dojo-crd

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  current kube-context is not 'kind-dojo' — targeting current context anyway."
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

echo
echo "✓ Namespace '$NS' ready."
echo "  Your mission:"
echo "    1. Define a CustomResourceDefinition: group dojo.local, kind Widget,"
echo "       scope Namespaced, schema that REQUIRES spec.size."
echo "    2. Apply it and wait until it is Established."
echo "    3. Create a Widget custom resource in namespace '$NS'."
echo "  Then run verify.sh."
