#!/usr/bin/env bash
# Plants "Keys to the Kingdom": a foothold pod in dojo-steal that mounts the
# node's root filesystem (hostPath: /) and is (mis)configured to tolerate the
# control-plane taint so it lands on the node holding admin.conf. The flag lives
# in a Secret in a LOCKED-DOWN namespace (dojo-vault, PSA restricted) that the
# foothold pod's own ServiceAccount CANNOT read. The only way in is the node's
# cluster-admin kubeconfig.
set -euo pipefail

NS=dojo-steal
VAULT=dojo-vault

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Targeting your current context anyway."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

kubectl create namespace "$NS"    --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace "$VAULT" --dry-run=client -o yaml | kubectl apply -f -

# Lock the vault namespace down: PSA 'restricted' forbids hostPath/privileged/
# root, so an attacker cannot simply schedule an escape pod INTO dojo-vault. The
# flag is only reachable with a credential stolen from outside it.
kubectl label ns "$VAULT" \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/audit=restricted --overwrite

# The crown-jewel Secret, in the restricted namespace. The foothold pod's SA has
# no RBAC to read it.
kubectl -n "$VAULT" create secret generic kingdom-keys \
  --from-literal=TLS_PRIVATE_KEY=decoy-not-the-flag \
  --from-literal=FLAG='KUBE{stolen_node_kubeconfig_is_cluster_admin}' \
  --dry-run=client -o yaml | kubectl apply -f -

# The foothold pod: mounts hostPath: / and tolerates the control-plane taint,
# modelling an over-permissive node agent / DaemonSet allowed onto the control
# plane. Its ServiceAccount (default/dojo-steal) has NO access to dojo-vault.
cat <<'YAML' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: foothold
  namespace: dojo-steal
  labels:
    app: foothold
spec:
  nodeSelector:
    node-role.kubernetes.io/control-plane: ""
  tolerations:
    - key: node-role.kubernetes.io/control-plane
      operator: Exists
      effect: NoSchedule
  containers:
    - name: tool
      image: nicolaka/netshoot:v0.13
      command: ["sh", "-c", "sleep 3600"]
      volumeMounts:
        - name: node-root
          mountPath: /host
  volumes:
    - name: node-root
      hostPath:
        path: /
        type: Directory
YAML

kubectl -n "$NS" wait --for=condition=Ready pod/foothold --timeout=90s >/dev/null 2>&1 || true

echo
echo "✓ Scenario deployed."
echo "  Planted:"
echo "    - Namespace '$VAULT' (PSA restricted) + Secret 'kingdom-keys' (FLAG=KUBE{...} + decoy)"
echo "    - Namespace '$NS' + pod 'foothold' (nicolaka/netshoot:v0.13) mounting hostPath '/' at /host,"
echo "      scheduled onto the CONTROL-PLANE node (tolerates its NoSchedule taint)"
echo
echo "  The foothold pod's ServiceAccount CANNOT read the flag (prove it — expect 'no'):"
echo "    kubectl auth can-i get secrets -n $VAULT \\"
echo "      --as=system:serviceaccount:$NS:default"
echo
echo "  Mission: from inside 'foothold', read the node's kubeconfig at"
echo "    /host/etc/kubernetes/admin.conf   (cluster-admin), then USE it to read"
echo "    the 'kingdom-keys' Secret in '$VAULT'. Submit the KUBE{...} flag."
echo
echo "  Get a shell with:  kubectl -n $NS exec -it foothold -- bash"
