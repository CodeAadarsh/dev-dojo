#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="dojo-sec-forensics"

echo "==> Setting up: Audit Log Forensics"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Plant the flag in a secret with an incriminating annotation
FLAG_B64=$(printf '%s' 'KUBE{audit_logs_never_lie}' | base64)
kubectl apply -f - << EOF
apiVersion: v1
kind: Secret
metadata:
  name: attacker-secret
  namespace: $NAMESPACE
  annotations:
    dojo.attack/technique: "T1552.001"
    dojo.attack/description: "Credentials from Files — attacker read this secret during the compromise"
    dojo.attack/timestamp: "2026-11-25T17:04:38Z"
type: Opaque
data:
  flag: $FLAG_B64
  username: $(printf '%s' 'exfiltrated-db-admin' | base64)
  password: $(printf '%s' 'hunter2-but-actually-stolen' | base64)
EOF

# Plant decoy secrets to make it less trivial
kubectl apply -f - << 'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: app-config
  namespace: dojo-sec-forensics
type: Opaque
data:
  api-key: ZGVjb3kta2V5LW5vdC10aGUtZmxhZw==
---
apiVersion: v1
kind: Secret
metadata:
  name: tls-cert
  namespace: dojo-sec-forensics
type: Opaque
data:
  cert: ZGVjb3ktY2VydC1ub3QtdGhlLWZsYWc=
EOF

# Simulated audit trail showing what the attacker did
kubectl apply -f - << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: audit-trail
  namespace: dojo-sec-forensics
  annotations:
    dojo.forensics/source: "kube-apiserver audit log (simulated)"
    dojo.forensics/timerange: "2026-11-25T17:04:30Z to 2026-11-25T17:04:45Z"
data:
  log: |
    {"timestamp":"2026-11-25T17:04:30Z","verb":"list","user":{"username":"system:serviceaccount:dojo-sec-forensics:default","uid":"abc-123"},"objectRef":{"resource":"pods","namespace":"dojo-sec-forensics"},"responseStatus":{"code":200},"sourceIPs":["10.244.0.5"]}
    {"timestamp":"2026-11-25T17:04:32Z","verb":"list","user":{"username":"system:serviceaccount:dojo-sec-forensics:default","uid":"abc-123"},"objectRef":{"resource":"secrets","namespace":"dojo-sec-forensics"},"responseStatus":{"code":200},"sourceIPs":["10.244.0.5"]}
    {"timestamp":"2026-11-25T17:04:35Z","verb":"get","user":{"username":"system:serviceaccount:dojo-sec-forensics:default","uid":"abc-123"},"objectRef":{"resource":"secrets","namespace":"dojo-sec-forensics","name":"app-config"},"responseStatus":{"code":200},"sourceIPs":["10.244.0.5"]}
    {"timestamp":"2026-11-25T17:04:38Z","verb":"get","user":{"username":"system:serviceaccount:dojo-sec-forensics:default","uid":"abc-123"},"objectRef":{"resource":"secrets","namespace":"dojo-sec-forensics","name":"attacker-secret"},"responseStatus":{"code":200},"sourceIPs":["10.244.0.5"]}
    {"timestamp":"2026-11-25T17:04:42Z","verb":"create","user":{"username":"system:serviceaccount:dojo-sec-forensics:default","uid":"abc-123"},"objectRef":{"resource":"pods","namespace":"dojo-sec-forensics","name":"exfil-pod"},"responseStatus":{"code":201},"sourceIPs":["10.244.0.5"]}
    {"timestamp":"2026-11-25T17:04:45Z","verb":"delete","user":{"username":"system:serviceaccount:dojo-sec-forensics:default","uid":"abc-123"},"objectRef":{"resource":"pods","namespace":"dojo-sec-forensics","name":"exfil-pod"},"responseStatus":{"code":200},"sourceIPs":["10.244.0.5"]}
  readme: |
    This simulates a Kubernetes API server audit log.
    Each line is a JSON audit event. The attacker:
    1. Listed pods to understand the environment
    2. Listed all secrets to find targets
    3. Read two specific secrets (one is the flag, one is a decoy)
    4. Created and quickly deleted an exfil pod
    Look for the secret the attacker read that contains a flag field.
EOF

kubectl apply -f - << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: clue-1
  namespace: dojo-sec-forensics
data:
  clue: "The attacker listed all secrets before reading specific ones. Look for verb=list then verb=get on resource=secrets."
EOF

kubectl apply -f - << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: clue-2
  namespace: dojo-sec-forensics
data:
  clue: "The attacker read TWO secrets. One is a decoy (app-config). The other contains the flag. Find its name in the audit trail's objectRef.name field."
EOF

echo ""
echo "==> Setup complete."
echo ""
echo "    Attack aftermath is ready in namespace '$NAMESPACE'."
echo "    Simulated audit trail: kubectl get configmap audit-trail -n $NAMESPACE -o jsonpath='{.data.log}'"
echo "    Follow the trail to find which secret the attacker read, then extract the flag field."
