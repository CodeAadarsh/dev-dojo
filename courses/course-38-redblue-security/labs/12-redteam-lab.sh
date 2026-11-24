#!/usr/bin/env bash
# Lab 12: Red Team Lab — full vulnerable cluster setup (capstone)
# This is the same as labs/bootstrap/install-vulnerable-lab.sh
# Delegates to it for the full setup
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
BOOTSTRAP="$REPO_ROOT/labs/bootstrap/install-vulnerable-lab.sh"

if [ -f "$BOOTSTRAP" ]; then
  echo "Running full Red Team Lab bootstrap..."
  bash "$BOOTSTRAP"
else
  echo "Bootstrap script not found at: $BOOTSTRAP"
  echo "Running inline setup..."

  # Inline fallback setup
  for NS in dojo-sec-redteam-app dojo-sec-redteam-data dojo-sec-redteam-ops; do
    kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
  done

  kubectl apply -f - <<'EOF'
# Overpermissive CI SA
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ci-runner-sa
  namespace: dojo-sec-redteam-ops
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: dojo-sec-redteam-ci-admin
subjects:
- kind: ServiceAccount
  name: ci-runner-sa
  namespace: dojo-sec-redteam-ops
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
---
# Frontend SA with cluster-wide pod/exec access
apiVersion: v1
kind: ServiceAccount
metadata:
  name: frontend-sa
  namespace: dojo-sec-redteam-app
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: dojo-sec-redteam-pod-exec
rules:
- apiGroups: [""]
  resources: ["pods", "pods/exec"]
  verbs: ["get", "list", "create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: dojo-sec-redteam-frontend-crb
subjects:
- kind: ServiceAccount
  name: frontend-sa
  namespace: dojo-sec-redteam-app
roleRef:
  kind: ClusterRole
  name: dojo-sec-redteam-pod-exec
  apiGroup: rbac.authorization.k8s.io
---
# Frontend pod (simulates vulnerable web app — entry point)
apiVersion: v1
kind: Pod
metadata:
  name: frontend
  namespace: dojo-sec-redteam-app
spec:
  serviceAccountName: frontend-sa
  containers:
  - name: app
    image: alpine:3.20
    command: [sleep, "86400"]
    securityContext:
      runAsUser: 0
    env:
    - name: DATABASE_HOST
      value: postgres.dojo-sec-redteam-data.svc.cluster.local
    - name: DATABASE_PASSWORD
      value: password123
---
# CI runner pod (high-value target)
apiVersion: v1
kind: Pod
metadata:
  name: ci-runner
  namespace: dojo-sec-redteam-ops
spec:
  serviceAccountName: ci-runner-sa
  containers:
  - name: runner
    image: alpine:3.20
    command: [sleep, "86400"]
---
# Secret with database credentials in data namespace
apiVersion: v1
kind: Secret
metadata:
  name: postgres-creds
  namespace: dojo-sec-redteam-data
type: Opaque
data:
  password: cGFzc3dvcmQxMjM=
  username: YWRtaW4=
EOF

  kubectl wait --for=condition=ready pod/frontend -n dojo-sec-redteam-app --timeout=90s
  kubectl wait --for=condition=ready pod/ci-runner -n dojo-sec-redteam-ops --timeout=90s
fi

echo ""
echo "Red Team Lab ready!"
echo ""
echo "Attack surface map:"
echo "  Entry: kubectl exec -n dojo-sec-redteam-app frontend -it -- sh"
echo ""
echo "Vulnerability checklist (find all 12):"
echo "  [ ] 1. API server anonymous auth"
echo "  [ ] 2. Debug endpoint env var leak"
echo "  [ ] 3. Frontend pod running as root"
echo "  [ ] 4. Auto-mounted SA token"
echo "  [ ] 5. Frontend SA cluster-wide pod list"
echo "  [ ] 6. Frontend SA pods/exec cluster-wide"
echo "  [ ] 7. CI runner SA is cluster-admin"
echo "  [ ] 8. No admission controller"
echo "  [ ] 9. No PodSecurity admission"
echo "  [ ] 10. Redis/Postgres weak credentials"
echo "  [ ] 11. Monitoring SA secrets:list"
echo "  [ ] 12. No audit alerting on DaemonSet creation"
