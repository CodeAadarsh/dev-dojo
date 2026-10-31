#!/usr/bin/env bash
# Plants the "NetworkPolicy Lockdown" scenario into dojo-netpol: a backend
# (nginx) + Service, a role=frontend client, and a role=other intruder. With no
# NetworkPolicy present, every pod can reach every other pod (allow-all default).
set -euo pipefail

NS=dojo-netpol

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Targeting your current context anyway."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

cat <<'YAML' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
  namespace: dojo-netpol
  labels:
    app: backend
spec:
  replicas: 1
  selector:
    matchLabels:
      app: backend
  template:
    metadata:
      labels:
        app: backend
    spec:
      containers:
        - name: backend
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
          readinessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 2
            periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: backend
  namespace: dojo-netpol
spec:
  selector:
    app: backend
  ports:
    - port: 80
      targetPort: 80
---
apiVersion: v1
kind: Pod
metadata:
  name: frontend
  namespace: dojo-netpol
  labels:
    role: frontend
spec:
  containers:
    - name: client
      image: busybox:1.36
      command: ["sh", "-c", "sleep 3600"]
---
apiVersion: v1
kind: Pod
metadata:
  name: intruder
  namespace: dojo-netpol
  labels:
    role: other
spec:
  containers:
    - name: client
      image: busybox:1.36
      command: ["sh", "-c", "sleep 3600"]
YAML

echo
echo "✓ Scenario deployed to namespace '$NS'."
echo "  Planted: backend (nginx:1.27-alpine) + Service, a role=frontend client, a role=other intruder."
echo "  Right now there is NO NetworkPolicy, so EVERY pod can reach backend:80. Confirm:"
echo "    kubectl -n $NS exec intruder   -- wget -qO- --timeout=3 http://backend | head -1"
echo "    kubectl -n $NS exec frontend   -- wget -qO- --timeout=3 http://backend | head -1"
echo "  Apply a default-deny plus a frontend-only allow (see brief), then run verify.sh."
echo "  NOTE: kind's kindnet does NOT enforce NetworkPolicy — the verifier checks the policy objects."
