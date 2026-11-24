#!/usr/bin/env bash
# Lab 04: Lateral Movement — multi-namespace token theft environment
set -euo pipefail

NS_FRONT="dojo-sec-lateral-front"
NS_BACK="dojo-sec-lateral-back"
NS_DATA="dojo-sec-lateral-data"

for ns in "$NS_FRONT" "$NS_BACK" "$NS_DATA"; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done

kubectl apply -f - <<'EOF'
# Frontend SA — can list pods cluster-wide (misconfiguration)
apiVersion: v1
kind: ServiceAccount
metadata:
  name: frontend-sa
  namespace: dojo-sec-lateral-front
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: dojo-sec-lateral-pod-reader
rules:
- apiGroups: [""]
  resources: ["pods", "pods/exec"]
  verbs: ["get", "list", "create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: dojo-sec-lateral-frontend-crb
subjects:
- kind: ServiceAccount
  name: frontend-sa
  namespace: dojo-sec-lateral-front
roleRef:
  kind: ClusterRole
  name: dojo-sec-lateral-pod-reader
  apiGroup: rbac.authorization.k8s.io
---
# Frontend foothold pod
apiVersion: v1
kind: Pod
metadata:
  name: frontend
  namespace: dojo-sec-lateral-front
spec:
  serviceAccountName: frontend-sa
  containers:
  - name: app
    image: alpine:3.20
    command: [sleep, "86400"]
---
# Backend SA — has secrets access in backend namespace
apiVersion: v1
kind: ServiceAccount
metadata:
  name: backend-sa
  namespace: dojo-sec-lateral-back
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: secret-reader
  namespace: dojo-sec-lateral-back
rules:
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: backend-sa-secrets
  namespace: dojo-sec-lateral-back
subjects:
- kind: ServiceAccount
  name: backend-sa
  namespace: dojo-sec-lateral-back
roleRef:
  kind: Role
  name: secret-reader
  apiGroup: rbac.authorization.k8s.io
---
# Backend pod — running with the backend SA
apiVersion: v1
kind: Pod
metadata:
  name: backend
  namespace: dojo-sec-lateral-back
spec:
  serviceAccountName: backend-sa
  containers:
  - name: app
    image: alpine:3.20
    command: [sleep, "86400"]
---
# Target secret in data namespace
apiVersion: v1
kind: Secret
metadata:
  name: database-credentials
  namespace: dojo-sec-lateral-data
type: Opaque
data:
  password: cHJvZF9kYl9wYXNzd29yZF9zdXBlcl9zZWNyZXQ=
  username: cHJvZF9hZG1pbg==
EOF

kubectl wait --for=condition=ready pod/frontend -n "$NS_FRONT" --timeout=90s
kubectl wait --for=condition=ready pod/backend -n "$NS_BACK" --timeout=90s

echo ""
echo "Lateral movement lab ready."
echo "Entry: kubectl exec -n $NS_FRONT frontend -it -- sh"
echo "Goal:  Hop from frontend → backend SA → data namespace secret"
echo "Path:  Read frontend SA token → exec into backend pod → steal backend token → read secret"
