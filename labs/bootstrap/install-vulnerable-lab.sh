#!/usr/bin/env bash
# Vulnerable Lab Bootstrap — install-vulnerable-lab.sh
# Deploys the full deliberately vulnerable cluster used by Module 12 and Challenge 15.
# Idempotent: re-running is safe.
set -euo pipefail

NS_VULN="dojo-sec-vuln"
NS_DATA="dojo-sec-data"
NS_INFRA="dojo-sec-infra"

echo "=== KUBE-DOJO Vulnerable Lab Bootstrap ==="
echo ""
echo "WARNING: This deploys intentionally misconfigured resources."
echo "         Run only on a local kind/minikube cluster, NOT on production."
echo ""

for ns in "$NS_VULN" "$NS_DATA" "$NS_INFRA"; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done

# ── dojo-sec-vuln: Overpermissive SA + web deployment ───────────────────────

kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vuln-web-sa
  namespace: $NS_VULN
  annotations:
    dojo.vuln/reason: "SA has cluster-wide secrets:list — attack vector 1"
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: vuln-secret-reader
  annotations:
    dojo.vuln/reason: "Overly broad — should be namespace-scoped, not cluster"
rules:
- apiGroups: [""]
  resources: ["secrets", "pods", "configmaps", "serviceaccounts"]
  verbs: ["get", "list"]
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: vuln-web-sa-cluster-reader
  annotations:
    dojo.vuln/reason: "Cross-cluster binding for a namespaced SA — attack vector 1"
subjects:
- kind: ServiceAccount
  name: vuln-web-sa
  namespace: $NS_VULN
roleRef:
  kind: ClusterRole
  name: vuln-secret-reader
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vuln-web
  namespace: $NS_VULN
  labels:
    app: vuln-web
spec:
  replicas: 1
  selector:
    matchLabels:
      app: vuln-web
  template:
    metadata:
      labels:
        app: vuln-web
    spec:
      serviceAccountName: vuln-web-sa
      automountServiceAccountToken: true
      containers:
      - name: web
        image: nginx:1.27-alpine
        resources:
          limits:
            cpu: "100m"
            memory: "64Mi"
EOF

# ── dojo-sec-data: Secret exposed as env var ────────────────────────────────

kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: db-creds
  namespace: $NS_DATA
  annotations:
    dojo.vuln/reason: "Secret accessible to any SA with cluster-wide secrets:list — attack vector 2"
type: Opaque
stringData:
  db-password: "prod-hunter2"
  db-host: "payments-db.internal:5432"
  db-user: "app_prod"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: db
  namespace: $NS_DATA
  labels:
    app: db
spec:
  replicas: 1
  selector:
    matchLabels:
      app: db
  template:
    metadata:
      labels:
        app: db
    spec:
      containers:
      - name: db
        image: alpine:3.20
        command: ["sh", "-c", "sleep 86400"]
        env:
        - name: DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: db-creds
              key: db-password
        resources:
          limits:
            cpu: "100m"
            memory: "64Mi"
EOF

# ── dojo-sec-infra: Privileged pod with hostPath ─────────────────────────────

kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: infra-pod
  namespace: $NS_INFRA
  labels:
    app: infra
  annotations:
    dojo.vuln/reason: "privileged=true + hostPath=/ — attack vector 3 (host escape)"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: infra
  template:
    metadata:
      labels:
        app: infra
    spec:
      containers:
      - name: infra
        image: alpine:3.20
        command: ["sh", "-c", "sleep 86400"]
        securityContext:
          privileged: true
        volumeMounts:
        - name: host-root
          mountPath: /host
        resources:
          limits:
            cpu: "200m"
            memory: "128Mi"
      volumes:
      - name: host-root
        hostPath:
          path: /
EOF

echo ""
echo "Vulnerable lab deployed."
echo ""
printf "%-32s %-28s %s\n" "Namespace" "Resource" "Vulnerability"
printf "%-32s %-28s %s\n" "────────────────────────────────" "────────────────────────────" "──────────────────────────────────"
printf "%-32s %-28s %s\n" "$NS_VULN" "ClusterRoleBinding" "SA has secrets:list cluster-wide"
printf "%-32s %-28s %s\n" "$NS_VULN" "Deployment/vuln-web" "automountServiceAccountToken=true"
printf "%-32s %-28s %s\n" "$NS_DATA" "Secret/db-creds" "Readable by vuln-web-sa"
printf "%-32s %-28s %s\n" "$NS_DATA" "Deployment/db" "DB_PASSWORD exposed as env var"
printf "%-32s %-28s %s\n" "$NS_INFRA" "Deployment/infra-pod" "privileged=true + hostPath=/"
echo ""
echo "Attack path:"
echo "  Step 1 — Initial access:  kubectl exec -n $NS_VULN deploy/vuln-web -- cat /var/run/secrets/kubernetes.io/serviceaccount/token"
echo "  Step 2 — Secret access:   kubectl get secret db-creds -n $NS_DATA --token=<stolen> -o jsonpath='{.data.db-password}'"
echo "  Step 3 — Host escape:     Deploy privileged pod with hostPath=/ → chroot /host"
echo "  Step 4 — Lateral move:    Use cluster-wide RBAC to reach $NS_INFRA"
echo "  Step 5 — Full access:     kubectl create clusterrolebinding pwned --clusterrole=cluster-admin --serviceaccount=$NS_VULN:vuln-web-sa"
echo ""
echo "Hardening path:"
echo "  1. kubectl delete clusterrolebinding vuln-web-sa-cluster-reader"
echo "  2. kubectl annotate secret db-creds dojo.hardened/secret=true -n $NS_DATA"
echo "  3. kubectl patch deployment infra-pod -n $NS_INFRA --type=json -p '[{\"op\":\"remove\",\"path\":\"/spec/template/spec/containers/0/securityContext/privileged\"}]'"
echo "  4. kubectl apply -f - <<EOF"
echo "     (NetworkPolicy deny-all in $NS_VULN)"
echo "     EOF"
echo "  5. kubectl label namespace $NS_VULN pod-security.kubernetes.io/enforce=restricted"
