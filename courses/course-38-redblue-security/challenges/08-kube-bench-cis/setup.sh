#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="dojo-sec-cis"

echo "==> Setting up: kube-bench CIS Hardening"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Store a simulated kube-bench output (since running actual kube-bench requires privileged access)
kubectl apply -f - << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: kube-bench-results
  namespace: dojo-sec-cis
  annotations:
    dojo.challenge/note: "Simulated kube-bench output for a kind cluster"
data:
  output: |
    [INFO] 1 Control Plane Security Configuration
    [INFO] 1.1 Control Plane Node Configuration Files
    [PASS] 1.1.1 Ensure that the API server pod specification file permissions are set to 600 or more restrictive
    [PASS] 1.1.2 Ensure that the API server pod specification file ownership is set to root:root
    [FAIL] 1.1.11 Ensure that the etcd data directory permissions are set to 700 or more restrictive
      -- Remediation: Run: chmod 700 /var/lib/etcd
    [INFO] 1.2 API Server
    [PASS] 1.2.1 Ensure that the --anonymous-auth argument is set to false
    [PASS] 1.2.2 Ensure that the --token-auth-file parameter is not set
    [PASS] 1.2.4 Ensure that the --kubelet-https argument is set to true
    [FAIL] 1.2.6 Ensure that the --authorization-mode argument includes Node
      -- Remediation: Edit the API server pod spec: add --authorization-mode=Node,RBAC
    [PASS] 1.2.7 Ensure that the --authorization-mode argument includes RBAC
    [FAIL] 1.2.9 Ensure that the --enable-admission-plugins includes EventRateLimit
      -- Remediation: Add EventRateLimit to --enable-admission-plugins
    [PASS] 1.2.16 Ensure that the --insecure-port argument is set to 0
    [FAIL] 1.2.22 Ensure that the --audit-log-path argument is set
      -- Remediation: Edit API server: add --audit-log-path=/var/log/apiserver/audit.log
    [INFO] 2 Etcd
    [PASS] 2.1 Ensure that the --cert-file and --key-file arguments are set as appropriate
    [FAIL] 2.2 Ensure that the --client-cert-auth argument is set to true
      -- Remediation: Edit etcd pod spec: add --client-cert-auth=true
    [INFO] 4 Worker Nodes
    [INFO] 4.2 Kubelet
    [PASS] 4.2.1 Ensure that the --anonymous-auth argument is set to false
    [PASS] 4.2.2 Ensure that the --authorization-mode argument is not set to AlwaysAllow
    [FAIL] 4.2.3 Ensure that the --client-ca-file argument is set as appropriate
      -- Remediation: Edit kubelet config: set clientCAFile to the CA cert path
    [INFO] 5 Kubernetes Policies
    [WARN] 5.1.1 Ensure that the cluster-admin role is only used where required
    [WARN] 5.2.1 Ensure that the cluster has at least one active PodSecurityPolicy
    [PASS] 5.4.1 Prefer using secrets as files over secrets as environment variables
    == Summary ==
    8 checks PASS
    6 checks FAIL
    3 checks WARN
    2 checks INFO
  kind_note: |
    Some checks (1.1.11 etcd permissions, 2.2 client-cert-auth) are expected to FAIL
    in kind clusters because kind manages these differently than production kubeadm clusters.
    The important ones to understand: 1.2.1 (anon-auth=false), 1.2.16 (insecure-port=0),
    4.2.1 (kubelet anon-auth), 4.2.2 (kubelet auth mode).
EOF

kubectl apply -f - << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: cis-checklist
  namespace: dojo-sec-cis
data:
  checklist: |
    CIS Checks to understand for this challenge:
    1.2.1  - API server: anonymous-auth must be false
    1.2.7  - API server: authorization-mode must include RBAC
    1.2.16 - API server: insecure-port must be 0
    4.2.1  - Kubelet: anonymous-auth must be false
    4.2.2  - Kubelet: authorization-mode must not be AlwaysAllow

    All 5 of these PASS on a properly configured kind cluster.
    The verifier checks these specific test IDs in the kube-bench output.
EOF

# Plant the flag
FLAG_B64=$(printf '%s' 'KUBE{cis_benchmark_level1_pass}' | base64)
kubectl apply -f - << EOF
apiVersion: v1
kind: Secret
metadata:
  name: cis-reward
  namespace: $NAMESPACE
type: Opaque
data:
  flag: $FLAG_B64
EOF

echo ""
echo "==> Setup complete."
echo ""
echo "    Read kube-bench results: kubectl get configmap kube-bench-results -n $NAMESPACE -o jsonpath='{.data.output}'"
echo "    Read the checklist: kubectl get configmap cis-checklist -n $NAMESPACE -o jsonpath='{.data.checklist}'"
echo "    Then run: bash verify.sh"
