#!/usr/bin/env bash
# Plants "Pivot Through the Pod": an 'internal-api' workload that serves a flag
# over plain HTTP on a ClusterIP Service, and a separate 'foothold' pod on the
# same flat pod network. There is NO NetworkPolicy — so the foothold can reach
# the internal API freely, exactly as a compromised pod would.
set -euo pipefail

NS=dojo-lateral

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Targeting your current context anyway."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

cat <<'YAML' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: internal-api-content
  namespace: dojo-lateral
data:
  index.html: |
    <!doctype html>
    <html>
      <head><title>internal-api</title></head>
      <body>
        <h1>internal-api (private)</h1>
        <p>This service assumes only the frontend can reach it.</p>
        <p>FLAG=KUBE{flat_network_enables_lateral_movement}</p>
      </body>
    </html>
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: internal-api
  namespace: dojo-lateral
  labels:
    app: internal-api
spec:
  replicas: 1
  selector:
    matchLabels:
      app: internal-api
  template:
    metadata:
      labels:
        app: internal-api
    spec:
      containers:
        - name: nginx
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
          volumeMounts:
            - name: content
              mountPath: /usr/share/nginx/html
              readOnly: true
      volumes:
        - name: content
          configMap:
            name: internal-api-content
---
apiVersion: v1
kind: Service
metadata:
  name: internal-api
  namespace: dojo-lateral
spec:
  selector:
    app: internal-api
  ports:
    - protocol: TCP
      port: 80
      targetPort: 80
---
apiVersion: v1
kind: Pod
metadata:
  name: foothold
  namespace: dojo-lateral
  labels:
    app: foothold
spec:
  containers:
    - name: tool
      image: nicolaka/netshoot:v0.13
      command: ["sh", "-c", "sleep 3600"]
YAML

kubectl -n "$NS" rollout status deploy/internal-api --timeout=90s >/dev/null 2>&1 || true
kubectl -n "$NS" wait --for=condition=Ready pod/foothold --timeout=90s >/dev/null 2>&1 || true

echo
echo "✓ Scenario deployed to namespace '$NS'."
echo "  Planted:"
echo "    - Deployment + Service 'internal-api' (nginx:1.27-alpine) serving FLAG=KUBE{...} on :80"
echo "    - Pod 'foothold' (nicolaka/netshoot:v0.13) on the SAME pod network"
echo "    - NO NetworkPolicy — the network is flat and allow-all by default"
echo
echo "  Mission: from inside 'foothold', reach 'internal-api' and capture the flag:"
echo "    kubectl -n $NS exec -it foothold -- bash"
echo "    curl -s http://internal-api.$NS.svc.cluster.local/"
echo "  Submit the KUBE{...} flag."
