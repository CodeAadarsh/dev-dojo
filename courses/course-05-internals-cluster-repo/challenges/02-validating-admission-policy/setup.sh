#!/usr/bin/env bash
# Plants the "Ban the Latest" scenario: a namespace to scope the policy to.
# It does NOT create the policy — that is the learner's job.
set -euo pipefail

NS=dojo-admission

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Targeting your current context anyway."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

# Idempotent namespace the policy binding must be scoped to.
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

# Label it so a well-written binding can target the namespace by label if desired.
kubectl label namespace "$NS" dojo-policy=enforce --overwrite >/dev/null

echo
echo "✓ Scenario ready."
echo "  Namespace : $NS  (labeled dojo-policy=enforce)"
echo
echo "  Your task: create a ValidatingAdmissionPolicy + ValidatingAdmissionPolicyBinding"
echo "  (admissionregistration.k8s.io/v1, CEL) that REJECTS any Pod/Deployment image"
echo "  tagged ':latest' or untagged, scoped to namespace '$NS'. Full policy YAML is"
echo "  in solution.md. Then run verify.sh."
echo
echo "  Quick self-test once your policy is applied:"
echo "    kubectl -n $NS run bad  --image=nginx:latest       --restart=Never --dry-run=server   # should FAIL"
echo "    kubectl -n $NS run good --image=nginx:1.27-alpine  --restart=Never --dry-run=server   # should PASS"
