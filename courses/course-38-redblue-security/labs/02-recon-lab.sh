#!/usr/bin/env bash
# Module 02 — Reconnaissance & Initial Access Lab
# Deploys an over-permissive SA, a fake dashboard, and an exposed default token
set -euo pipefail

NS="dojo-lab-recon"

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: default
  namespace: $NS
---
# Over-broad default SA (the misconfiguration)
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: recon-lab-default-sa
subjects:
- kind: ServiceAccount
  name: default
  namespace: $NS
roleRef:
  kind: ClusterRole
  name: view
  apiGroup: rbac.authorization.k8s.io
---
# Fake Kubernetes Dashboard (nginx serving a placeholder)
apiVersion: v1
kind: ConfigMap
metadata:
  name: fake-dashboard-html
  namespace: $NS
data:
  index.html: |
    <html><head><title>Kubernetes Dashboard</title></head>
    <body>
    <h1>Kubernetes Dashboard</h1>
    <p>Cluster: production-k8s-cluster-01</p>
    <p>Nodes: 3 | Namespaces: 12 | Pods: 47</p>
    <pre>Bearer token (admin): eyJhbGciOiJSUzI1NiIsImtpZCI6InRlc3QifQ.REDACTED</pre>
    </body></html>
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dashboard
  namespace: $NS
  labels:
    app: dashboard
spec:
  replicas: 1
  selector:
    matchLabels:
      app: dashboard
  template:
    metadata:
      labels:
        app: dashboard
    spec:
      containers:
      - name: nginx
        image: nginx:1.27-alpine
        volumeMounts:
        - name: html
          mountPath: /usr/share/nginx/html
        resources:
          limits:
            cpu: "100m"
            memory: "64Mi"
      volumes:
      - name: html
        configMap:
          name: fake-dashboard-html
---
apiVersion: v1
kind: Service
metadata:
  name: dashboard-svc
  namespace: $NS
spec:
  selector:
    app: dashboard
  ports:
  - port: 80
    targetPort: 80
---
# A pod that uses the default SA (which has the over-broad binding)
apiVersion: v1
kind: Pod
metadata:
  name: app-pod
  namespace: $NS
  labels:
    app: app
spec:
  containers:
  - name: app
    image: curlimages/curl:8.10.1
    command: ["sh", "-c", "sleep 86400"]
    resources:
      limits:
        cpu: "100m"
        memory: "64Mi"
  restartPolicy: Always
EOF

echo "Recon lab ready. Namespace: $NS"
echo ""
echo "Recon exercises:"
echo "  1. kubectl exec app-pod -n $NS -- cat /var/run/secrets/kubernetes.io/serviceaccount/token"
echo "  2. Use the token to list all namespaces (default SA has 'view' cluster-wide)"
echo "  3. kubectl port-forward svc/dashboard-svc 8080:80 -n $NS — visit http://localhost:8080"
echo "  4. Identify what information the dashboard leaks without authentication"
