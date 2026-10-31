#!/usr/bin/env bash
# Deletes the dojo cluster. Your whole lab is disposable — this is the reset.
set -euo pipefail
echo "Deleting kind cluster 'dojo'…"
kind delete cluster --name dojo
echo "✓ gone. Recreate with: bash labs/bootstrap/create-cluster.sh"
