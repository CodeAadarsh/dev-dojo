#!/usr/bin/env bash
# Module 01 — MITRE ATT&CK Kill Chain Lab
# Sets up an attack playground pod with an over-permissive SA to explore the full kill chain
set -euo pipefail

NS="dojo-lab-killchain"

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: target-sa
  namespace: $NS
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: killchain-lab-reader
rules:
- apiGroups: [""]
  resources: ["pods", "secrets", "configmaps", "serviceaccounts"]
  verbs: ["get", "list"]
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: killchain-lab-binding
subjects:
- kind: ServiceAccount
  name: target-sa
  namespace: $NS
roleRef:
  kind: ClusterRole
  name: killchain-lab-reader
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: v1
kind: Secret
metadata:
  name: db-secret
  namespace: $NS
type: Opaque
stringData:
  password: "super-secret-lab-pass"
---
apiVersion: v1
kind: Pod
metadata:
  name: target-app
  namespace: $NS
  labels:
    app: target
spec:
  serviceAccountName: target-sa
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

echo "Kill chain lab ready. Namespace: $NS"
echo ""
echo "Kill chain exercise:"
echo "  1. Exec into target-app and steal the SA token"
echo "  2. Use the token to list secrets in $NS"
echo "  3. Use the token to enumerate other namespaces"
echo "  4. Identify the MITRE tactics each step maps to"
