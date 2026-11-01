#!/usr/bin/env bash
# Sets up the GitOps Handoff challenge: creates dojo-cicd-gitops namespace
# and plants an application.yaml stub in the work directory.
# Idempotent — uses kubectl apply throughout.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/06-gitops-handoff"
NS="dojo-cicd-gitops"

# Warn (don't fail) if not on the dojo context
CURRENT_CTX=$(kubectl config current-context 2>/dev/null || echo "unknown")
[ "$CURRENT_CTX" = "kind-dojo" ] \
  || echo "WARNING: current kubectl context is '$CURRENT_CTX', not 'kind-dojo'. Run: kubectl config use-context kind-dojo"

# Warn (don't fail) if ArgoCD not installed
kubectl get ns argocd >/dev/null 2>&1 \
  || echo "WARNING: ArgoCD not found. Install it: bash labs/bootstrap/install-argocd.sh"

mkdir -p "$WORK"

# ── dojo-cicd-gitops namespace ────────────────────────────────────────────────
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

# ── application.yaml stub ─────────────────────────────────────────────────────
if [ ! -f "$WORK/application.yaml" ]; then
  cat > "$WORK/application.yaml" << 'YAMEOF'
# application.yaml — complete this ArgoCD Application and apply it with:
#   kubectl apply -f ~/.kube-dojo-work/06-gitops-handoff/application.yaml -n argocd
#
# Requirements:
#   - metadata.namespace: argocd
#   - spec.destination.namespace: dojo-cicd-gitops
#   - spec.syncPolicy.automated must be set
#   - Use any public repo; the guestbook example is reliable:
#       repoURL: https://github.com/argoproj/argocd-example-apps.git
#       path: guestbook
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: dojo-gitops-handoff
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/argoproj/argocd-example-apps.git
    targetRevision: HEAD
    path: guestbook
  destination:
    server: https://kubernetes.default.svc
    namespace: dojo-cicd-gitops   # <-- required
  syncPolicy:
    automated: {}                  # <-- required: enables automated reconciliation
    syncOptions:
    - CreateNamespace=true
YAMEOF
fi

echo
echo "Namespace      : $NS created"
echo "Work directory : $WORK"
echo
echo "Task           : complete $WORK/application.yaml and apply it:"
echo "                 kubectl apply -f $WORK/application.yaml -n argocd"
echo
echo "Then wait for sync (watch status in real time):"
echo "  kubectl -n argocd get application dojo-gitops-handoff -w"
echo "  # or: kubectl -n argocd get applications.argoproj.io"
echo
echo "Prereqs        : ArgoCD installed (bash labs/bootstrap/install-argocd.sh)"
echo "Verify + flag  : bash courses/course-25-cicd/challenges/06-gitops-handoff/verify.sh"
