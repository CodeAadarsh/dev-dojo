#!/usr/bin/env bash
# Module 11 — CIS Hardening & Incident Response Lab
# Creates several deliberately non-CIS-compliant resources for kube-bench exercises
set -euo pipefail

NS="dojo-lab-cis"

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f - <<EOF
# CIS violation 1: default SA bound to cluster-admin
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: default-sa-cluster-admin-VIOLATION
  annotations:
    dojo.cis/violation: "CIS 5.1.5 — Ensure that default service accounts are not bound to active cluster-admin role"
subjects:
- kind: ServiceAccount
  name: default
  namespace: $NS
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
---
# CIS violation 2: pod with hostPID and hostNetwork
apiVersion: v1
kind: Pod
metadata:
  name: hostpid-pod
  namespace: $NS
  annotations:
    dojo.cis/violation: "CIS 5.2.2 — Minimize the admission of containers wishing to share the host process ID namespace"
  labels:
    app: hostpid-violator
spec:
  hostPID: true
  hostNetwork: true
  containers:
  - name: c
    image: alpine:3.20
    command: ["sh", "-c", "sleep 86400"]
    resources:
      limits:
        cpu: "200m"
        memory: "128Mi"
  restartPolicy: Always
---
# CIS violation 3: container running as root
apiVersion: v1
kind: Pod
metadata:
  name: root-container
  namespace: $NS
  annotations:
    dojo.cis/violation: "CIS 5.2.6 — Minimize the admission of root containers"
  labels:
    app: root-violator
spec:
  containers:
  - name: c
    image: alpine:3.20
    command: ["sh", "-c", "sleep 86400"]
    securityContext:
      runAsUser: 0
    resources:
      limits:
        cpu: "100m"
        memory: "64Mi"
  restartPolicy: Always
---
# CIS violation 4: no resource limits
apiVersion: v1
kind: Pod
metadata:
  name: no-limits-pod
  namespace: $NS
  annotations:
    dojo.cis/violation: "CIS 5.3.1 — Ensure CPU and memory limits are set for all containers"
  labels:
    app: no-limits-violator
spec:
  containers:
  - name: c
    image: alpine:3.20
    command: ["sh", "-c", "sleep 86400"]
    # No resources.limits — CIS violation
  restartPolicy: Always
---
# ConfigMap listing the violations for reference
apiVersion: v1
kind: ConfigMap
metadata:
  name: cis-violations
  namespace: $NS
data:
  violations: |
    1. ClusterRoleBinding 'default-sa-cluster-admin-VIOLATION' — CIS 5.1.5
    2. Pod 'hostpid-pod' with hostPID=true, hostNetwork=true — CIS 5.2.2
    3. Pod 'root-container' running as UID 0 — CIS 5.2.6
    4. Pod 'no-limits-pod' with no resource limits — CIS 5.3.1
  fix_command: "Run kube-bench to discover these + more: kubectl run kube-bench --restart=Never --image=aquasec/kube-bench:latest --overrides='{\"spec\":{\"hostPID\":true,\"nodeSelector\":{\"kubernetes.io/os\":\"linux\"}}}'"
EOF

echo "CIS hardening lab ready. Namespace: $NS"
echo ""
echo "4 deliberate CIS violations deployed. Find them and fix them."
echo ""
echo "Run kube-bench to find CIS failures:"
echo "  kubectl apply -f https://raw.githubusercontent.com/aquasecurity/kube-bench/main/job.yaml"
echo "  kubectl logs job/kube-bench | grep FAIL"
echo ""
echo "List the violations:"
echo "  kubectl get configmap cis-violations -n $NS -o jsonpath='{.data.violations}'"
echo ""
echo "Fix challenge: bring all 4 violations into compliance and re-run kube-bench."
