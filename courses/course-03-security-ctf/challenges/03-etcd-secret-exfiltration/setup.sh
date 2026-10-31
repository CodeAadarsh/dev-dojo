#!/usr/bin/env bash
# Plants the "Straight From etcd" scenario: a Secret whose plaintext lives in
# etcd with NO encryption-at-rest, readable with node access that never touches
# the API server or RBAC — the etcd link of the Module 01 attack surface.
set -euo pipefail

NS=dojo-etcd

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Targeting your current context anyway."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

# A juicy-looking backup Secret. The decoy AWS key is NOT the flag.
kubectl -n "$NS" create secret generic vault-backup \
  --from-literal=AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE \
  --from-literal=FLAG='KUBE{etcd_plaintext_bypasses_rbac}' \
  --dry-run=client -o yaml | kubectl apply -f -

echo
echo "✓ Scenario deployed to namespace '$NS'."
echo "  Planted:"
echo "    - Secret 'vault-backup' in namespace '$NS' (holds FLAG=KUBE{...} plus a decoy AWS key)"
echo "    - No EncryptionConfiguration on this cluster → the value is PLAINTEXT in etcd"
echo
echo "  Mission: do NOT use 'kubectl get secret'. Read the flag straight out of etcd"
echo "  from the control-plane NODE, bypassing the API server and RBAC:"
echo
echo "    docker exec dojo-control-plane sh -c 'ETCDCTL_API=3 etcdctl \\"
echo "      --cacert=/etc/kubernetes/pki/etcd/ca.crt \\"
echo "      --cert=/etc/kubernetes/pki/etcd/server.crt \\"
echo "      --key=/etc/kubernetes/pki/etcd/server.key \\"
echo "      get /registry/secrets/$NS/vault-backup' | strings | grep KUBE"
