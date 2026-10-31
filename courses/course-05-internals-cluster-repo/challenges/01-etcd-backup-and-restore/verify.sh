#!/usr/bin/env bash
# Verifier for "Back Up the Brain". Confirms a VALID etcd snapshot exists on the
# control-plane node, then prints the flag. Exit 0 = solved, 1 = not yet.
# Node-level challenge: the lab cluster is kind (name 'dojo'), so we inspect the
# control-plane node directly via `docker exec dojo-control-plane ...`.
set -uo pipefail

NODE=dojo-control-plane
SNAP=/var/lib/etcd-backup/snapshot.db
FLAG='KUBE{etcd_snapshot_is_the_only_real_dr}'

fail() { echo "✗ $1"; exit 1; }

# 0) The node container must be reachable at all.
docker exec "$NODE" true 2>/dev/null \
  || fail "control-plane node '$NODE' not reachable — is the kind 'dojo' cluster up? (kind get nodes --name dojo)"

# 1) The snapshot file must exist on the node.
docker exec "$NODE" test -f "$SNAP" 2>/dev/null \
  || fail "no snapshot at $NODE:$SNAP — take one with 'etcdctl snapshot save' (see brief.md)"

# 2) It must be a REAL etcd snapshot. `snapshot status` reads the local file (no
#    certs/endpoint needed) and fails on a truncated or non-snapshot file, so an
#    empty `touch`ed path cannot pass this check.
STATUS=$(docker exec "$NODE" sh -c \
  "ETCDCTL_API=3 etcdctl --write-out=table snapshot status $SNAP" 2>/dev/null) \
  || fail "'etcdctl snapshot status $SNAP' failed — the file exists but is not a valid etcd snapshot"

[ -n "$STATUS" ] \
  || fail "snapshot status returned nothing — the file is not a valid etcd snapshot"

echo "✓ control-plane node        : $NODE"
echo "✓ snapshot present          : $SNAP"
echo "✓ snapshot status (valid)   :"
echo "$STATUS" | sed 's/^/    /'
echo
echo "All checks passed. Submit this flag in the platform:"
echo
echo "    $FLAG"
