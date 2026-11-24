#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="dojo-sec-incident"

echo "==> Setting up: Incident Playbook"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Plant the "malicious" pod
kubectl apply -f - << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: malicious-pod
  namespace: dojo-sec-incident
  labels:
    app: malicious
    dojo.attack/status: active
  annotations:
    dojo.attack/technique: "T1059 - Command and Scripting Interpreter"
    dojo.attack/timestamp: "2026-11-25T10:30:00Z"
    dojo.challenge/note: "This simulates a compromised pod. Follow PICERL to handle it."
spec:
  containers:
  - name: malicious
    image: busybox
    command: [sleep, "3600"]
EOF

# Plant suspicious ClusterRoleBinding (gives default SA cluster-admin)
kubectl apply -f - << 'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: suspicious-crb
  annotations:
    dojo.attack/note: "Attacker planted this CRB to maintain persistent cluster-admin access"
subjects:
- kind: ServiceAccount
  name: default
  namespace: dojo-sec-incident
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
EOF

# Plant leaked credentials secret
kubectl apply -f - << 'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: leaked-creds
  namespace: dojo-sec-incident
  annotations:
    dojo.attack/note: "Attacker left this after exfiltrating credentials"
type: Opaque
data:
  password: c3VwZXJTZWNyZXRQYXNzd29yZDEyMw==
  api-key: ZXhmaWx0cmF0ZWQtYXBpLWtleS0xMjM0NQ==
EOF

# Plant the flag for the verifier to retrieve
FLAG_B64=$(printf '%s' 'KUBE{detect_contain_recover_in_order}' | base64)
kubectl apply -f - << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: incident-reward
  namespace: $NAMESPACE
data:
  flag_b64: $FLAG_B64
  hint: "Complete all 4 PICERL steps: Identify, Contain, Eradicate, Recover — then run verify.sh"
EOF

echo ""
echo "==> Setup complete. Incident simulation is active."
echo ""
echo "    Attack artifacts planted:"
echo "    - Pod: malicious-pod (label: dojo.attack/status=active)"
echo "    - ClusterRoleBinding: suspicious-crb (gives default SA cluster-admin)"
echo "    - Secret: leaked-creds (contains 'stolen' credentials)"
echo ""
echo "    Your PICERL steps:"
echo "    1. IDENTIFY: kubectl label pod malicious-pod -n $NAMESPACE dojo.incident/identified=true"
echo "    2. CONTAIN:  kubectl label pod malicious-pod -n $NAMESPACE dojo.incident/contained=true"
echo "    3. ERADICATE: kubectl delete clusterrolebinding suspicious-crb"
echo "    4. RECOVER:  kubectl delete secret leaked-creds -n $NAMESPACE && kubectl create secret generic rotated-creds --from-literal=password=new-pass -n $NAMESPACE"
echo ""
echo "    Then run: bash verify.sh"
