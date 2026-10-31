#!/usr/bin/env bash
# Plants the "GitOps or It Didn't Happen" scenario. Deliberately minimal:
# it only prepares the target namespace and confirms Argo CD is present.
# Creating the Application is the learner's job.
set -euo pipefail

NS=dojo-gitops

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Targeting your current context anyway."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

if kubectl get ns argocd >/dev/null 2>&1; then
  echo "✓ Argo CD namespace 'argocd' found."
else
  echo "⚠  Namespace 'argocd' is MISSING — Argo CD does not look installed."
  echo "   Install it first:  bash labs/bootstrap/install-argocd.sh"
fi

echo
echo "✓ Scenario prepared."
echo "  Target namespace '$NS' is ready for an Argo CD Application to populate."
echo "  Nothing was deployed into it — that's your job via GitOps."
echo
echo "Next:"
echo "  1. Author an Application (in the 'argocd' namespace) pointing at"
echo "     https://github.com/argoproj/argocd-example-apps  path 'guestbook',"
echo "     destination namespace '$NS', with syncPolicy.automated (prune + selfHeal)."
echo "  2. Apply it and let it sync."
echo "  3. Run verify.sh."
