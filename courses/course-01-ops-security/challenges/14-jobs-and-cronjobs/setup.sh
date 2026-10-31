#!/usr/bin/env bash
# Plants the "Batch It" scenario: just an empty namespace. The learner creates
# the Job and CronJob themselves — that's the whole exercise.
set -euo pipefail

NS=dojo-batch

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Targeting your current context anyway."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

echo
echo "✓ Scenario ready: empty namespace '$NS' created (nothing else planted)."
echo "  Create (1) a Job that runs a short task to completion, and"
echo "         (2) a CronJob scheduled every minute, both in '$NS'."
echo "  Give the Job a moment to finish, then run verify.sh."
