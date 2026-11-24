#!/usr/bin/env bash
# Module 12 — The Red Team Lab
# Full vulnerable cluster — same architecture as challenge 15 setup
# Namespaces: dojo-sec-vuln, dojo-sec-data, dojo-sec-infra
set -euo pipefail

NS_VULN="dojo-sec-vuln"
NS_DATA="dojo-sec-data"
NS_INFRA="dojo-sec-infra"

echo "Deploying full vulnerable cluster for Module 12 — Red Team Lab"
echo ""

for ns in "$NS_VULN" "$NS_DATA" "$NS_INFRA"; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done

# ── dojo-sec-vuln: Entry point ───────────────────────────────────────────────

kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vuln-web-sa
  namespace: $NS_VULN
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: vuln-secret-reader
rules:
- apiGroups: [""]
  resources: ["secrets", "pods", "configmaps", "serviceaccounts"]
  verbs: ["get", "list"]
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: vuln-web-sa-cluster-reader
subjects:
- kind: ServiceAccount
  name: vuln-web-sa
  namespace: $NS_VULN
roleRef:
  kind: ClusterRole
  name: vuln-secret-reader
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vuln-web
  namespace: $NS_VULN
  labels:
    app: vuln-web
spec:
  replicas: 1
  selector:
    matchLabels:
      app: vuln-web
  template:
    metadata:
      labels:
        app: vuln-web
    spec:
      serviceAccountName: vuln-web-sa
      containers:
      - name: web
        image: nginx:1.27-alpine
        resources:
          limits:
            cpu: "100m"
            memory: "64Mi"
EOF

# ── dojo-sec-data: Data tier ─────────────────────────────────────────────────

kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: db-creds
  namespace: $NS_DATA
type: Opaque
stringData:
  db-password: "prod-hunter2"
  db-host: "payments-db.internal:5432"
  db-user: "app_prod"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: db
  namespace: $NS_DATA
  labels:
    app: db
spec:
  replicas: 1
  selector:
    matchLabels:
      app: db
  template:
    metadata:
      labels:
        app: db
    spec:
      containers:
      - name: db
        image: alpine:3.20
        command: ["sh", "-c", "sleep 86400"]
        env:
        - name: DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: db-creds
              key: db-password
        resources:
          limits:
            cpu: "100m"
            memory: "64Mi"
EOF

# ── dojo-sec-infra: Privileged tier ──────────────────────────────────────────

kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: infra-pod
  namespace: $NS_INFRA
  labels:
    app: infra
spec:
  replicas: 1
  selector:
    matchLabels:
      app: infra
  template:
    metadata:
      labels:
        app: infra
    spec:
      containers:
      - name: infra
        image: alpine:3.20
        command: ["sh", "-c", "sleep 86400"]
        securityContext:
          privileged: true
        volumeMounts:
        - name: host-root
          mountPath: /host
        resources:
          limits:
            cpu: "200m"
            memory: "128Mi"
      volumes:
      - name: host-root
        hostPath:
          path: /
EOF

echo ""
echo "Vulnerable cluster ready."
echo ""
printf "%-30s %s\n" "Namespace" "Misconfiguration"
printf "%-30s %s\n" "─────────────────────────────" "──────────────────────────────────────"
printf "%-30s %s\n" "$NS_VULN" "SA with cluster-wide secrets:list"
printf "%-30s %s\n" "$NS_DATA" "DB secret exposed as env var"
printf "%-30s %s\n" "$NS_INFRA" "privileged=true + hostPath=/"
echo ""
echo "Attack path:"
echo "  1. kubectl exec -n $NS_VULN deploy/vuln-web -- cat /var/run/secrets/.../token"
echo "  2. Use token to list secrets in $NS_DATA → find db-password"
echo "  3. Create privileged pod → chroot /host → host compromise"
echo "  4. Use cluster-wide RBAC to pivot to $NS_INFRA"
echo ""
echo "Harden after attacking:"
echo "  kubectl delete clusterrolebinding vuln-web-sa-cluster-reader"
echo "  kubectl label namespace $NS_VULN pod-security.kubernetes.io/enforce=restricted"
