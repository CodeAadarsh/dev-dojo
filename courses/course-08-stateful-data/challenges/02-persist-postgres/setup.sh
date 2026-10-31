#!/usr/bin/env bash
# Plants the "Persist Postgres" scenario: creates the dojo-db namespace.
# The learner deploys Postgres with a PVC, Secret, and Service from scratch.
set -euo pipefail

NS=dojo-db

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Targeting current context anyway."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

echo
echo "✓ Namespace '$NS' ready."
echo
echo "  Your mission — create all three objects in $NS:"
echo
echo "  1. A Secret containing POSTGRES_DB, POSTGRES_USER, POSTGRES_PASSWORD"
echo "  2. A PVC (ReadWriteOnce, any size >= 1Gi, standard StorageClass)"
echo "     mounted at /var/lib/postgresql/data in the Deployment"
echo "  3. A Deployment using image postgres:16-alpine, env sourced from the Secret"
echo "  4. A ClusterIP Service on port 5432"
echo
echo "  Then prove persistence (brief.md Step 3) before running verify.sh."
