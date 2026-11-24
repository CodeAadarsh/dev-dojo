#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="dojo-sec-bench"

echo "==> Setting up: kube-bench CIS Hardening"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# ServiceAccount + RBAC for the watcher to monitor and write configmap
kubectl apply -f - << 'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: bench-watcher
  namespace: dojo-sec-bench
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: bench-watcher-role
  namespace: dojo-sec-bench
rules:
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["create", "patch", "get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: bench-watcher-rb
  namespace: dojo-sec-bench
subjects:
- kind: ServiceAccount
  name: bench-watcher
  namespace: dojo-sec-bench
roleRef:
  kind: Role
  name: bench-watcher-rb
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: bench-watcher-crb-reader
rules:
- apiGroups: ["rbac.authorization.k8s.io"]
  resources: ["clusterrolebindings"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: bench-watcher-crb-reader-binding
subjects:
- kind: ServiceAccount
  name: bench-watcher
  namespace: dojo-sec-bench
roleRef:
  kind: ClusterRole
  name: bench-watcher-crb-reader
  apiGroup: rbac.authorization.k8s.io
EOF

# The offending ClusterRoleBinding — represents CIS finding 5.1.1
kubectl apply -f - << 'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: overprivileged-binding
  annotations:
    dojo.cis/finding: "5.1.1 — cluster-admin role should not be bound to service accounts or users"
    dojo.cis/severity: "CRITICAL"
    dojo.cis/remediation: "Delete this ClusterRoleBinding and create a narrower Role with least-privilege grants"
subjects:
- kind: ServiceAccount
  name: default
  namespace: dojo-sec-bench
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
EOF

# Simulated kube-bench output configmap
kubectl apply -f - << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: kube-bench-report
  namespace: dojo-sec-bench
  annotations:
    dojo.bench/generated: "simulated kube-bench output — real tool at https://github.com/aquasecurity/kube-bench"
data:
  report.txt: |
    == Kubernetes Benchmark v1.9 ==

    [INFO] 1 Control Plane Security Configuration
    [INFO] 1.1 API Server
    [PASS] 1.1.1 Ensure that the API server pod specification file permissions are set to 600 or more restrictive
    [PASS] 1.1.2 Ensure that the API server pod specification file ownership is set to root:root
    [FAIL] 1.2.1 Ensure that the --anonymous-auth argument is set to false
           REMEDIATION: Edit the API server pod spec and set --anonymous-auth=false
    [FAIL] 1.2.6 Ensure that the --AlwaysPullImages admission control plugin is set
           REMEDIATION: Edit kube-apiserver manifest, add AlwaysPullImages to --enable-admission-plugins
    [PASS] 1.2.7 Ensure that the --authorization-mode argument is not set to AlwaysAllow
    [PASS] 1.3.1 Ensure that the --terminated-pod-gc-threshold argument is set appropriately

    [INFO] 2 etcd
    [PASS] 2.1 Ensure that the --cert-file and --key-file arguments are set appropriately
    [PASS] 2.2 Ensure that the --client-cert-auth argument is set to true

    [INFO] 4 Worker Node Security Configuration
    [INFO] 4.2 Kubelet
    [PASS] 4.2.1 Ensure that the --anonymous-auth argument is set to false
    [FAIL] 4.2.2 Ensure that the --authorization-mode argument is not set to AlwaysAllow
           REMEDIATION: Edit kubelet config and set authorization.mode to Webhook
    [PASS] 4.2.3 Ensure that the --client-ca-file argument is set appropriately

    [INFO] 5 Kubernetes Policies
    [INFO] 5.1 RBAC and Service Accounts
    [FAIL] 5.1.1 Ensure that the cluster-admin role is only used where required
           REMEDIATION: Remove ClusterRoleBinding 'overprivileged-binding' which grants cluster-admin
           to ServiceAccount 'default' in namespace 'dojo-sec-bench'. Create a narrower Role instead.
    [FAIL] 5.1.2 Minimize access to secrets
           REMEDIATION: Review ClusterRoles that grant get/list/watch on secrets
    [PASS] 5.1.3 Minimize wildcard use in Roles and ClusterRoles
    [INFO] 5.2 Pod Security Standards
    [FAIL] 5.2.1 Ensure that admission controllers enforce Pod Security Standards
           REMEDIATION: Add pod-security.kubernetes.io/enforce=restricted label to namespaces
    [PASS] 5.4.1 Prefer using Secrets as files over Secrets as environment variables

    == Summary ==
    5 checks FAILED
    8 checks PASSED
    0 checks WARNED

    == Critical Remediation Required ==
    1. CRB overprivileged-binding: cluster-admin bound to default SA in dojo-sec-bench
       Fix: kubectl delete clusterrolebinding overprivileged-binding
EOF

# Watcher pod — polls for the CRB deletion, then writes the flag
kubectl apply -f - << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: bench-watcher
  namespace: dojo-sec-bench
spec:
  serviceAccountName: bench-watcher
  containers:
  - name: watcher
    image: bitnami/kubectl:1.28
    command: [sh, -c]
    args:
    - |
      echo "Watcher started. Polling for removal of overprivileged-binding CRB..."
      while true; do
        if ! kubectl get clusterrolebinding overprivileged-binding >/dev/null 2>&1; then
          echo "CRB removed! Writing flag..."
          kubectl create configmap cis-hardening-flag \
            -n dojo-sec-bench \
            --from-literal=flag="KUBE{cis_benchmark_cluster_admin_removed}" \
            --from-literal=finding="5.1.1 REMEDIATED: cluster-admin ClusterRoleBinding deleted" \
            --dry-run=client -o yaml | kubectl apply -f -
          echo "Flag written."
          break
        fi
        echo "CRB still exists. Waiting..."
        sleep 5
      done
      sleep 600
  restartPolicy: Never
EOF

echo ""
echo "==> Setup complete."
echo ""
echo "    The CIS report is at: kubectl get configmap kube-bench-report -n $NAMESPACE -o jsonpath='{.data.report\\.txt}'"
echo ""
echo "    Your task:"
echo "    1. Read the report and understand finding 5.1.1"
echo "    2. Delete the offending binding: kubectl delete clusterrolebinding overprivileged-binding"
echo "    3. Wait 10s, then get the flag: kubectl get configmap cis-hardening-flag -n $NAMESPACE -o jsonpath='{.data.flag}'"
