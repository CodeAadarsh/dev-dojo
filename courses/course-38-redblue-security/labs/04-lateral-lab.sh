#!/usr/bin/env bash
# Module 04 — Lateral Movement Lab
# 2 namespaces with cross-namespace RBAC to practice token pivoting
set -euo pipefail

NS_A="dojo-lab-lateral-src"
NS_B="dojo-lab-lateral-dst"

kubectl create namespace "$NS_A" --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace "$NS_B" --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: app-sa
  namespace: $NS_A
---
# SA in A can list pods and configmaps in B
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: b-reader
  namespace: $NS_B
rules:
- apiGroups: [""]
  resources: ["configmaps", "pods"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: a-to-b
  namespace: $NS_B
subjects:
- kind: ServiceAccount
  name: app-sa
  namespace: $NS_A
roleRef:
  kind: Role
  name: b-reader
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: v1
kind: Pod
metadata:
  name: source-pod
  namespace: $NS_A
  labels:
    app: source
spec:
  serviceAccountName: app-sa
  containers:
  - name: c
    image: curlimages/curl:8.10.1
    command: ["sh", "-c", "sleep 86400"]
    resources:
      limits:
        cpu: "100m"
        memory: "64Mi"
  restartPolicy: Always
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: target-data
  namespace: $NS_B
data:
  sensitive_config: "db-host=prod-db.internal connection-string=postgresql://admin:lab-pass@prod-db:5432/payments"
  flag: "You pivoted to namespace B using the stolen token from namespace A"
---
apiVersion: v1
kind: Pod
metadata:
  name: target-pod
  namespace: $NS_B
  labels:
    app: target
spec:
  containers:
  - name: c
    image: nginx:1.27-alpine
    resources:
      limits:
        cpu: "100m"
        memory: "64Mi"
  restartPolicy: Always
EOF

echo "Lateral movement lab ready."
echo "Source namespace: $NS_A | Target namespace: $NS_B"
echo ""
echo "Exercise:"
echo "  1. kubectl exec source-pod -n $NS_A -- cat /var/run/secrets/kubernetes.io/serviceaccount/token"
echo "  2. Use the token to list configmaps in $NS_B"
echo "  3. Find and read target-data"
echo ""
echo "Defense questions:"
echo "  - Why should app-sa NOT have cross-namespace access?"
echo "  - How would audit logs reveal this lateral movement?"
