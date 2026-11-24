#!/usr/bin/env bash
set -euo pipefail

NS_A="dojo-sec-lateral-a"
NS_B="dojo-sec-lateral-b"
NS_C="dojo-sec-lateral-c"

for ns in "$NS_A" "$NS_B" "$NS_C"; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done

# ── Namespace A: foothold ──────────────────────────────────────────────────────

kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: foothold-sa
  namespace: $NS_A
---
# foothold-sa can list secrets and pods in namespace B only
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: b-reader
  namespace: $NS_B
rules:
- apiGroups: [""]
  resources: ["secrets", "pods"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: foothold-to-b
  namespace: $NS_B
subjects:
- kind: ServiceAccount
  name: foothold-sa
  namespace: $NS_A
roleRef:
  kind: Role
  name: b-reader
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: v1
kind: Pod
metadata:
  name: entry-point
  namespace: $NS_A
  labels:
    app: entry-point
    dojo.challenge: "10-lateral-movement-chain"
spec:
  serviceAccountName: foothold-sa
  containers:
  - name: attacker
    image: curlimages/curl:8.10.1
    command: ["sh", "-c", "sleep 86400"]
    resources:
      limits:
        cpu: "100m"
        memory: "64Mi"
  restartPolicy: Always
EOF

# ── Namespace B: pivot ──────────────────────────────────────────────────────────

# Service account for the api-server pod in B
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: api-sa
  namespace: $NS_B
---
# api-sa can list configmaps in namespace C
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: c-configmap-reader
  namespace: $NS_C
rules:
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: api-to-c
  namespace: $NS_C
subjects:
- kind: ServiceAccount
  name: api-sa
  namespace: $NS_B
roleRef:
  kind: Role
  name: c-configmap-reader
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: v1
kind: Pod
metadata:
  name: api-server
  namespace: $NS_B
  labels:
    app: api-server
spec:
  serviceAccountName: api-sa
  containers:
  - name: api
    image: nginx:1.27-alpine
    resources:
      limits:
        cpu: "100m"
        memory: "64Mi"
  restartPolicy: Always
EOF

# Plant hop-two-token: a secret in namespace B containing a copy of api-sa's token
# (In real attacks, attackers find SA tokens mounted in pods or stored as secrets)
# We simulate this by creating an explicit secret
API_SA_TOKEN=$(kubectl create token api-sa -n "$NS_B" --duration=24h 2>/dev/null || echo "")
if [ -n "$API_SA_TOKEN" ]; then
  kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: hop-two-token
  namespace: $NS_B
  annotations:
    kubernetes.io/note: "Simulates a leaked service account token found in namespace B"
type: Opaque
stringData:
  token: "$API_SA_TOKEN"
  hint: "This is the api-sa service account token. It has access to configmaps in dojo-sec-lateral-c."
EOF
fi

# ── Namespace C: prize ─────────────────────────────────────────────────────────

kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: final-flag
  namespace: $NS_C
  labels:
    dojo.challenge: "10-lateral-movement-chain"
data:
  flag: "KUBE{three_hops_to_node_compromise}"
  story: "You made it. Three hops across three namespaces using stolen service account tokens. This is exactly how real lateral movement works in Kubernetes."
---
apiVersion: v1
kind: Secret
metadata:
  name: hop-three-creds
  namespace: $NS_C
  annotations:
    kubernetes.io/note: "Red herring — the flag is in the ConfigMap"
type: Opaque
stringData:
  password: "not-the-flag"
EOF

echo ""
echo "Setup complete."
echo ""
echo "Namespaces: $NS_A → $NS_B → $NS_C"
echo ""
echo "Start here:"
echo "  kubectl exec -n $NS_A entry-point -- cat /var/run/secrets/kubernetes.io/serviceaccount/token"
echo ""
echo "Then use that token to explore namespace B, find hop-two-token, use it to reach namespace C."
