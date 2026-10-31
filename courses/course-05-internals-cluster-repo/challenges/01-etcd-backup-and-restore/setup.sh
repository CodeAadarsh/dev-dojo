#!/usr/bin/env bash
# Plants the "Back Up the Brain" scenario: ensures the on-node backup directory
# exists. It does NOT take the snapshot — that is the learner's job.
set -euo pipefail

NS=dojo-etcd
NODE=dojo-control-plane
BACKUP_DIR=/var/lib/etcd-backup

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. This challenge needs the kind 'dojo' cluster."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

# Marker namespace so `kubectl get ns | grep dojo-` lists this lab's state.
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

# The challenge is node-level: make sure the control-plane node container is reachable.
if ! docker exec "$NODE" true 2>/dev/null; then
  echo "✗ Control-plane node container '$NODE' is not reachable."
  echo "  Is the kind 'dojo' cluster up?  Try: kind get nodes --name dojo"
  exit 1
fi

# Idempotent: create the backup directory inside the node where the snapshot must land.
docker exec "$NODE" mkdir -p "$BACKUP_DIR"

echo
echo "✓ Scenario ready."
echo "  Marker namespace    : $NS"
echo "  Backup dir on node  : $NODE:$BACKUP_DIR  (created, empty)"
echo
echo "  Your task: take an etcd snapshot and save it to"
echo "    $NODE:$BACKUP_DIR/snapshot.db"
echo "  using 'ETCDCTL_API=3 etcdctl ... snapshot save' with the certs under"
echo "  /etc/kubernetes/pki/etcd/ (full command in brief.md), then run verify.sh."
