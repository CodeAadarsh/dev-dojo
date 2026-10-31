#!/usr/bin/env bash
# Plants the "Drift Detective" scenario: an Argo CD Application with auto-sync
# but selfHeal DISABLED, synced healthy, then a manual scale to introduce drift
# that the controller will NOT fix until the learner turns selfHeal on.
set -euo pipefail

ARGONS=argocd
NS=dojo-drift
APP=drift-detective

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Targeting your current context anyway."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

if ! kubectl get ns "$ARGONS" >/dev/null 2>&1; then
  echo "⚠  Namespace 'argocd' is MISSING — Argo CD does not look installed."
  echo "   Install it first:  bash labs/bootstrap/install-argocd.sh"
  echo "   Cannot plant the scenario without Argo CD. Exiting."
  exit 1
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

echo "Creating Application '$APP' (automated sync, selfHeal=false)…"
cat <<'YAML' | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: drift-detective
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/argoproj/argocd-example-apps
    path: guestbook
    targetRevision: HEAD
  destination:
    server: https://kubernetes.default.svc
    namespace: dojo-drift
  syncPolicy:
    automated:
      prune: true
      selfHeal: false
    syncOptions:
      - CreateNamespace=true
YAML

echo "Waiting for '$APP' to reach Synced (up to ~2 min)…"
SYNCED=""
for _ in $(seq 1 60); do
  S=$(kubectl -n "$ARGONS" get application.argoproj.io "$APP" \
    -o jsonpath='{.status.sync.status}' 2>/dev/null || true)
  if [ "$S" = "Synced" ]; then SYNCED=1; break; fi
  sleep 2
done

if [ -z "$SYNCED" ]; then
  echo "⚠  '$APP' has not reported Synced yet. Give it a moment, or force a sync:"
  echo "     argocd app sync $APP"
  echo "   Continuing to plant drift anyway once guestbook-ui exists."
fi

echo "Waiting for the 'guestbook-ui' Deployment to appear in '$NS'…"
for _ in $(seq 1 60); do
  if kubectl -n "$NS" get deploy guestbook-ui >/dev/null 2>&1; then break; fi
  sleep 2
done

if kubectl -n "$NS" get deploy guestbook-ui >/dev/null 2>&1; then
  echo "Introducing drift: scaling 'guestbook-ui' to 4 replicas (Git declares 1)…"
  kubectl -n "$NS" scale deploy guestbook-ui --replicas=4
else
  echo "⚠  'guestbook-ui' not found in '$NS' yet — the app may still be syncing."
  echo "   Once it exists, introduce drift manually:"
  echo "     kubectl -n $NS scale deploy guestbook-ui --replicas=4"
fi

echo
echo "✓ Scenario planted."
echo "  Application '$APP' runs with automated sync but selfHeal=false."
echo "  'guestbook-ui' was scaled to 4 while Git says 1 → the app will show OutOfSync"
echo "  and the controller will NOT revert it."
echo
echo "Next:"
echo "  1. Confirm the drift:"
echo "       kubectl -n $ARGONS get application $APP -o jsonpath='{.status.sync.status}{\"\\n\"}'"
echo "       kubectl -n $NS get deploy guestbook-ui"
echo "  2. Enable automated selfHeal on '$APP' so Argo CD reverts the drift."
echo "  3. Run verify.sh."
