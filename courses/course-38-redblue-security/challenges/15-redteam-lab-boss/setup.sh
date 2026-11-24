#!/usr/bin/env bash
set -euo pipefail

NS_BOSS="dojo-sec-boss"
NS_VAULT="dojo-sec-boss-vault"

echo "==> Setting up: Red Team Lab Boss"

kubectl create namespace "$NS_BOSS" --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace "$NS_VAULT" --dry-run=client -o yaml | kubectl apply -f -

# --- The dangerous ClusterRoleBinding ---
kubectl apply -f - << EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: dangerous-crb
  annotations:
    dojo.attack/note: "Grants cluster-admin to default SA in dojo-sec-boss — DELETE this in hardening phase"
subjects:
- kind: ServiceAccount
  name: default
  namespace: $NS_BOSS
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
EOF

# --- The exposed app (auto-mounts cluster-admin token) ---
kubectl apply -f - << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: exposed-app
  namespace: $NS_BOSS
spec:
  replicas: 1
  selector:
    matchLabels:
      app: exposed-app
  template:
    metadata:
      labels:
        app: exposed-app
    spec:
      serviceAccountName: default
      containers:
      - name: app
        image: busybox
        command: [sleep, "3600"]
---
apiVersion: v1
kind: Service
metadata:
  name: exposed-app-svc
  namespace: $NS_BOSS
spec:
  selector:
    app: exposed-app
  ports:
  - port: 80
    targetPort: 8080
EOF

# --- The Crown Jewels secret ---
CROWN_B64=$(printf '%s' 'crown-jewels-value-attack-found-this' | base64)
kubectl apply -f - << EOF
apiVersion: v1
kind: Secret
metadata:
  name: crown-jewels
  namespace: $NS_VAULT
  annotations:
    dojo.attack/note: "High-value secret — attacker reads this after pivoting with stolen token"
type: Opaque
data:
  secret: $CROWN_B64
  hint: $(printf '%s' 'You found the crown jewels! Now prove it in attack-progress ConfigMap and harden the cluster.' | base64)
EOF

# --- Reward flag ---
FLAG_B64=$(printf '%s' 'KUBE{full_kill_chain_owned_then_hardened}' | base64)
kubectl apply -f - << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: boss-reward
  namespace: $NS_BOSS
data:
  flag_b64: $FLAG_B64
EOF

echo ""
echo "==> Setup complete. The vulnerable lab is ready."
echo ""
echo "    Attack surface:"
echo "    - Pod 'exposed-app' in $NS_BOSS (runs with default SA + cluster-admin token)"
echo "    - ClusterRoleBinding 'dangerous-crb' gives default SA cluster-admin"
echo "    - Secret 'crown-jewels' in $NS_VAULT (accessible via stolen cluster-admin token)"
echo ""
echo "    Attack: exec into exposed-app, steal token, use it to read crown-jewels,"
echo "            then create ConfigMap 'attack-progress' in $NS_BOSS"
echo ""
echo "    Harden: delete dangerous-crb, set automountServiceAccountToken=false,"
echo "            add NetworkPolicy, rotate crown-jewels"
echo ""
echo "    Run: bash verify.sh when both attack AND hardening are complete"
