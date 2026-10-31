#!/usr/bin/env bash
# Plants the "Escape the Box" scenario: a privileged pod with the node root
# filesystem mounted at /host, pinned to node 'dojo-worker', plus a root-only
# flag file on that node's disk (reachable ONLY by escaping the container).
set -euo pipefail

NS=dojo-escape
NODE=dojo-worker
FLAG='KUBE{privileged_pod_equals_node_root}'

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Targeting your current context anyway."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

# The flag lives on the NODE's disk, not in the API. We plant it by execing into
# the kind node container directly (this is the setup author's privilege — the
# learner has to EARN this same access by escaping the pod).
if ! docker ps --format '{{.Names}}' | grep -qx "$NODE"; then
  echo "✗ kind node container '$NODE' is not running."
  echo "  This challenge needs the 'dojo' kind cluster up. Run:"
  echo "    bash labs/bootstrap/create-cluster.sh"
  exit 1
fi

docker exec "$NODE" sh -c "printf '%s\n' '$FLAG' > /root/flag.txt && chmod 600 /root/flag.txt && chown root:root /root/flag.txt"
echo "✓ Planted /root/flag.txt (mode 0600, owner root) on node '$NODE'."

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

# A deliberately insecure debug pod: privileged + host root filesystem mounted,
# pinned to the node that holds the flag. No PSA labels on this namespace.
cat <<YAML | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: escape-pod
  namespace: ${NS}
  labels:
    app: escape-pod
spec:
  nodeName: ${NODE}
  containers:
    - name: debug
      image: alpine:3.20
      command: ["sh", "-c", "sleep infinity"]
      securityContext:
        privileged: true
      volumeMounts:
        - name: host
          mountPath: /host
  volumes:
    - name: host
      hostPath:
        path: /
        type: Directory
YAML

kubectl -n "$NS" wait --for=condition=Ready pod/escape-pod --timeout=60s || true

echo
echo "✓ Scenario deployed to namespace '$NS'."
echo "  Pod 'escape-pod' is PRIVILEGED with the node root filesystem mounted at /host,"
echo "  pinned to node '$NODE'. A root-only flag file waits on that node's disk."
echo
echo "  Next: get a shell in the pod and escape to the node to read it:"
echo "    kubectl -n $NS exec -it escape-pod -- sh"
