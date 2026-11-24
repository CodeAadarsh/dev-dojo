#!/usr/bin/env bash
set -euo pipefail

NS1="dojo-sec-lateral"
NS2="dojo-sec-lateral-hop2"
NS3="dojo-sec-lateral-hop3"

echo "==> Setting up: Lateral Movement Chain"

for ns in "$NS1" "$NS2" "$NS3"; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done

# --- Hop 1 SA and RBAC ---
# hop1-sa in NS1 — can get pods in NS2
kubectl apply -f - << EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: hop1-sa
  namespace: $NS1
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: hop1-pod-reader
  namespace: $NS2
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: hop1-pod-reader-binding
  namespace: $NS2
subjects:
- kind: ServiceAccount
  name: hop1-sa
  namespace: $NS1
roleRef:
  kind: Role
  name: hop1-pod-reader
  apiGroup: rbac.authorization.k8s.io
EOF

# --- Hop 2 SA and RBAC ---
# hop2-sa in NS2 — can get secrets in NS3
kubectl apply -f - << EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: hop2-sa
  namespace: $NS2
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: hop2-secret-reader
  namespace: $NS3
rules:
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: hop2-secret-reader-binding
  namespace: $NS3
subjects:
- kind: ServiceAccount
  name: hop2-sa
  namespace: $NS2
roleRef:
  kind: Role
  name: hop2-secret-reader
  apiGroup: rbac.authorization.k8s.io
EOF

# --- Pod in NS1 running as hop1-sa (attackers pivot from here) ---
kubectl apply -f - << EOF
apiVersion: v1
kind: Pod
metadata:
  name: hop1-pod
  namespace: $NS1
  labels:
    app: hop1
spec:
  serviceAccountName: hop1-sa
  automountServiceAccountToken: true
  containers:
  - name: app
    image: busybox
    command: [sleep, "3600"]
EOF

# --- Pod in NS2 running as hop2-sa ---
kubectl apply -f - << EOF
apiVersion: v1
kind: Pod
metadata:
  name: hop2-pod
  namespace: $NS2
  labels:
    app: hop2
spec:
  serviceAccountName: hop2-sa
  automountServiceAccountToken: true
  containers:
  - name: app
    image: busybox
    command: [sleep, "3600"]
EOF

# --- The final treasure secret in NS3 ---
FLAG_B64=$(printf '%s' 'KUBE{three_hops_to_node_compromise}' | base64)
kubectl apply -f - << EOF
apiVersion: v1
kind: Secret
metadata:
  name: final-treasure
  namespace: $NS3
  annotations:
    dojo.challenge/note: "Three hops to get here — initial access → hop1-sa → hop2-sa → this secret"
type: Opaque
data:
  flag: $FLAG_B64
  username: $(printf '%s' 'crown-jewel-admin' | base64)
  password: $(printf '%s' 'very-secret-password-that-the-attacker-stole' | base64)
EOF

echo ""
echo "==> Setup complete."
echo ""
echo "    Starting point: pods in $NS1"
echo "    kubectl get pods -n $NS1"
echo "    exec into hop1-pod and steal the SA token"
echo "    Use stolen token to discover pods in $NS2"
echo "    exec into hop2-pod and steal hop2-sa token"
echo "    Use hop2-sa token to read secrets in $NS3"
echo ""
echo "    Run: bash verify.sh when you've found the flag"
