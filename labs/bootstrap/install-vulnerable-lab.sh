#!/usr/bin/env bash
# install-vulnerable-lab.sh — Red Team Lab Bootstrap
# Deploys a deliberately misconfigured Kubernetes environment for course-38 Module 12.
# 12 intentional vulnerabilities across 3 namespaces.
# CAUTION: This creates real security misconfigurations — use in a lab cluster ONLY.
set -euo pipefail

echo "=== Red Team Lab Bootstrap ==="
echo "WARNING: This creates a deliberately insecure environment."
echo "Use ONLY on a dedicated lab cluster, never on production."
echo ""

for NS in dojo-sec-redteam-app dojo-sec-redteam-data dojo-sec-redteam-ops; do
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
done

# ── Vuln 1: API server anonymous access ──
# Not applied here — requires API server flag change.
# In a kind cluster it defaults to anonymous=true (which is the vulnerability).
echo "[1/12] Vuln 1 (anonymous API): relies on kind default --anonymous-auth=true"

# ── Vuln 2: Debug endpoint env leak ──
kubectl apply -n dojo-sec-redteam-app -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
  namespace: dojo-sec-redteam-app
data:
  debug: "true"
  version: "1.0.0"
EOF
echo "[2/12] Vuln 2 (debug endpoint): ConfigMap debug=true set"

# ── Vuln 3: Frontend pod running as root ──
# ── Vuln 4: SA token auto-mounted ──
kubectl apply -n dojo-sec-redteam-app -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: frontend-sa
  namespace: dojo-sec-redteam-app
# automountServiceAccountToken not set → defaults to true (Vuln 4)
---
apiVersion: v1
kind: Pod
metadata:
  name: frontend
  namespace: dojo-sec-redteam-app
  labels:
    app: frontend
spec:
  serviceAccountName: frontend-sa
  # automountServiceAccountToken not set → auto-mounts (Vuln 4)
  containers:
  - name: app
    image: alpine:3.20
    command:
    - sh
    - -c
    - |
      # Simulate a web server with command injection
      while true; do
        echo -e "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"status\":\"ok\",\"debug\":true,\"env\":\"DATABASE_PASSWORD=$DATABASE_PASSWORD\"}" \
          | nc -l -p 8080 -q 1 2>/dev/null || true
      done
    ports:
    - containerPort: 8080
    securityContext:
      runAsUser: 0        # Vuln 3: running as root
    env:
    - name: DATABASE_PASSWORD
      value: "password123"      # Vuln 2: leaked via debug endpoint
    - name: DATABASE_HOST
      value: "postgres.dojo-sec-redteam-data.svc.cluster.local"
EOF
echo "[3/12] Vuln 3 (root container): frontend pod runAsUser=0"
echo "[4/12] Vuln 4 (SA auto-mount): frontend-sa auto-mounts token"

# ── Vuln 5: Frontend SA has cluster-wide pod list ──
# ── Vuln 6: Frontend SA has pods/exec cluster-wide ──
kubectl apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: dojo-sec-redteam-pod-exec-role
rules:
- apiGroups: [""]
  resources: ["pods", "pods/exec", "pods/log"]
  verbs: ["get", "list", "create"]   # Vuln 5+6
- apiGroups: [""]
  resources: ["namespaces"]
  verbs: ["list", "get"]
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
  name: dojo-sec-redteam-pod-exec-role
  apiGroup: rbac.authorization.k8s.io
EOF
echo "[5/12] Vuln 5 (cluster-wide pod list): frontend-sa can list pods in all namespaces"
echo "[6/12] Vuln 6 (cluster-wide exec): frontend-sa can exec into any pod"

# ── Vuln 7: CI runner SA is cluster-admin ──
kubectl apply -n dojo-sec-redteam-ops -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ci-runner-sa
  namespace: dojo-sec-redteam-ops
---
apiVersion: v1
kind: Pod
metadata:
  name: ci-runner
  namespace: dojo-sec-redteam-ops
  labels:
    app: ci-runner
spec:
  serviceAccountName: ci-runner-sa
  containers:
  - name: runner
    image: alpine:3.20
    command: [sleep, "86400"]
    env:
    - name: GITHUB_TOKEN
      value: "ghp_FAKE_LAB_TOKEN_NOT_REAL"
EOF
kubectl apply -f - <<'EOF'
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
EOF
echo "[7/12] Vuln 7 (CI cluster-admin): ci-runner-sa is cluster-admin"

# ── Vuln 8+9: No admission controller, no PodSecurity ──
# These are absent-by-default on a fresh kind cluster.
echo "[8/12] Vuln 8 (no admission controller): Kyverno/OPA not installed"
echo "[9/12] Vuln 9 (no PodSecurity): PodSecurity admission not enabled"

# ── Vuln 10: Weak credentials ──
kubectl apply -n dojo-sec-redteam-data -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: postgres-creds
  namespace: dojo-sec-redteam-data
type: Opaque
data:
  username: YWRtaW4=
  password: cGFzc3dvcmQxMjM=   # password123 — Vuln 10
---
# Redis with no auth (simulated)
apiVersion: v1
kind: ConfigMap
metadata:
  name: redis-config
  namespace: dojo-sec-redteam-data
data:
  redis.conf: |
    # No requirepass set — Vuln 10
    bind 0.0.0.0
    protected-mode no
---
apiVersion: v1
kind: Pod
metadata:
  name: data-pod
  namespace: dojo-sec-redteam-data
spec:
  containers:
  - name: data
    image: alpine:3.20
    command: [sleep, "86400"]
    env:
    - name: DB_PASSWORD
      valueFrom:
        secretKeyRef:
          name: postgres-creds
          key: password
EOF
echo "[10/12] Vuln 10 (weak creds): postgres password=password123, Redis no auth"

# ── Vuln 11: Monitoring SA has secrets:list cluster-wide ──
kubectl apply -n dojo-sec-redteam-ops -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: monitoring-sa
  namespace: dojo-sec-redteam-ops
---
apiVersion: v1
kind: Pod
metadata:
  name: monitoring
  namespace: dojo-sec-redteam-ops
  labels:
    app: monitoring
spec:
  serviceAccountName: monitoring-sa
  containers:
  - name: prometheus
    image: alpine:3.20
    command: [sleep, "86400"]
EOF
kubectl apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: dojo-sec-redteam-monitoring-role
rules:
- apiGroups: [""]
  resources: ["pods", "nodes", "services", "endpoints", "secrets"]  # Vuln 11: secrets in list
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: dojo-sec-redteam-monitoring-crb
subjects:
- kind: ServiceAccount
  name: monitoring-sa
  namespace: dojo-sec-redteam-ops
roleRef:
  kind: ClusterRole
  name: dojo-sec-redteam-monitoring-role
  apiGroup: rbac.authorization.k8s.io
EOF
echo "[11/12] Vuln 11 (monitoring SA secrets:list): monitoring-sa can list secrets cluster-wide"

# ── Vuln 12: No audit alerting ──
# Absent by default.
echo "[12/12] Vuln 12 (no audit alerts): no audit log policy configured"

# Wait for all pods
kubectl wait --for=condition=ready pod/frontend -n dojo-sec-redteam-app --timeout=120s || true
kubectl wait --for=condition=ready pod/ci-runner -n dojo-sec-redteam-ops --timeout=120s || true
kubectl wait --for=condition=ready pod/monitoring -n dojo-sec-redteam-ops --timeout=120s || true
kubectl wait --for=condition=ready pod/data-pod -n dojo-sec-redteam-data --timeout=120s || true

echo ""
echo "=== Red Team Lab Ready ==="
echo ""
echo "All 12 vulnerabilities deployed."
echo ""
echo "Start the attack:"
echo "  kubectl exec -n dojo-sec-redteam-app frontend -it -- sh"
echo ""
echo "Reference: courses/course-38-redblue-security/modules/12-redteam-lab.md"
echo ""
echo "To tear down:"
echo "  for NS in dojo-sec-redteam-app dojo-sec-redteam-data dojo-sec-redteam-ops; do"
echo "    kubectl delete namespace \$NS"
echo "  done"
echo "  kubectl delete clusterrolebinding dojo-sec-redteam-ci-admin dojo-sec-redteam-frontend-crb dojo-sec-redteam-monitoring-crb"
echo "  kubectl delete clusterrole dojo-sec-redteam-pod-exec-role dojo-sec-redteam-monitoring-role"
