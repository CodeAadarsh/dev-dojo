#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="dojo-sec-boss"

echo "==> Setting up: Red Team Lab Boss"
echo "    This is a multi-phase challenge — attack and defend."
echo ""

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# --- ServiceAccounts and RBAC ---

# Overprivileged SA (the security mistake)
kubectl apply -f - << 'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: overprivileged-sa
  namespace: dojo-sec-boss
  annotations:
    dojo.boss/note: "This SA has cluster-admin — a critical misconfiguration to find and fix"
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: boss-overprivileged-binding
  annotations:
    dojo.boss/hardening-target: "1"
    dojo.boss/delete-to-harden: "true"
subjects:
- kind: ServiceAccount
  name: overprivileged-sa
  namespace: dojo-sec-boss
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
EOF

# Writer SA for the attack pod to store tokens
kubectl apply -f - << 'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: writer-sa
  namespace: dojo-sec-boss
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: writer-role
  namespace: dojo-sec-boss
rules:
- apiGroups: [""]
  resources: ["configmaps", "secrets"]
  verbs: ["create", "patch", "get", "list"]
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: writer-rb
  namespace: dojo-sec-boss
subjects:
- kind: ServiceAccount
  name: overprivileged-sa
  namespace: dojo-sec-boss
roleRef:
  kind: Role
  name: writer-role
  apiGroup: rbac.authorization.k8s.io
EOF

# --- Fake IMDS service (attack surface 1) ---
kubectl apply -f - << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: boss-imds-nginx
  namespace: dojo-sec-boss
data:
  nginx.conf: |
    events {}
    http {
      server {
        listen 80;
        location /latest/meta-data/iam/security-credentials/ {
          return 200 "node-role\n";
        }
        location /latest/meta-data/iam/security-credentials/node-role {
          return 200 '{"SecretAccessKey":"token1-imds-creds-stolen"}';
        }
        location / { return 404; }
      }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: boss-imds
  namespace: dojo-sec-boss
spec:
  replicas: 1
  selector:
    matchLabels:
      app: boss-imds
  template:
    metadata:
      labels:
        app: boss-imds
    spec:
      containers:
      - name: nginx
        image: nginx:1.27-alpine
        volumeMounts:
        - name: conf
          mountPath: /etc/nginx/nginx.conf
          subPath: nginx.conf
      volumes:
      - name: conf
        configMap:
          name: boss-imds-nginx
---
apiVersion: v1
kind: Service
metadata:
  name: fake-imds-svc
  namespace: dojo-sec-boss
spec:
  selector:
    app: boss-imds
  ports:
  - port: 80
    targetPort: 80
EOF

# --- Secrets (attack surface 3) ---
kubectl apply -f - << 'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: db-creds
  namespace: dojo-sec-boss
  annotations:
    dojo.boss/hardening-target: "3"
type: Opaque
data:
  flag: dG9rZW4zLXNlY3JldC1lbnVtZXJhdGVk
  username: cHJvZC1kYi1hZG1pbg==
  password: c3VwZXItc2VjcmV0LXBhc3M=
EOF

# --- Attack pod (the attacker foothold) ---
kubectl apply -f - << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: attack-pod
  namespace: dojo-sec-boss
  annotations:
    dojo.boss/purpose: "Your foothold — a compromised application pod"
spec:
  serviceAccountName: overprivileged-sa
  containers:
  - name: attacker
    image: bitnami/kubectl:1.28
    command: ["sh", "-c"]
    args:
    - |
      echo "Attack pod ready. Full kill chain exercise."
      echo ""
      echo "ATTACK SURFACES:"
      echo "  1. IMDS: curl http://fake-imds-svc/latest/meta-data/iam/security-credentials/node-role"
      echo "     → Write token to attack-token-1"
      echo "  2. SA token abuse: cat /var/run/secrets/kubernetes.io/serviceaccount/token"
      echo "     → Write token to attack-token-2"
      echo "  3. Secret enumeration: kubectl get secret db-creds -n dojo-sec-boss -o jsonpath='{.data.flag}' | base64 -d"
      echo "     → Write token to attack-token-3"
      echo "  4. Privileged pod: kubectl run pwned --image=busybox:1.36 --restart=Never --privileged=true -n dojo-sec-boss -- sleep 60"
      echo "     → Write token to attack-token-4"
      echo "  5. Etcd exploration: kubectl get cm -A | grep -c kube-system"
      echo "     → Write token to attack-token-5"
      sleep 7200
    env:
    - name: DB_PASSWORD
      value: "super-secret-pass"
    - name: DB_HOST
      value: "prod-postgres.dojo-sec-boss.svc"
  restartPolicy: Never
EOF

echo ""
echo "==> Setup complete."
echo ""
echo "    Attack pod: kubectl exec -it attack-pod -n $NAMESPACE -- sh"
echo ""
echo "    Complete all 5 attack surfaces, then apply all 5 hardenings."
echo "    Run verify.sh when done."
