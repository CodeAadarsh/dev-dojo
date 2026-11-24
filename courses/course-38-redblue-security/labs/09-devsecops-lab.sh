#!/usr/bin/env bash
# Lab 09: DevSecOps Pipeline Security — sets up a local Gitea + Act environment for CI injection lab
set -euo pipefail

NAMESPACE="dojo-sec-ci"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -n "$NAMESPACE" -f - <<'EOF'
# Simulated CI runner pod with dangerous SA permissions (represents Jenkins/GitHub Actions self-hosted)
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ci-runner-sa
  namespace: dojo-sec-ci
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: dojo-sec-ci-runner-admin
subjects:
- kind: ServiceAccount
  name: ci-runner-sa
  namespace: dojo-sec-ci
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
---
# CI runner pod — simulates a self-hosted GitHub Actions runner with cluster-admin
apiVersion: v1
kind: Pod
metadata:
  name: ci-runner
  namespace: dojo-sec-ci
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
      value: "ghp_FAKE_TOKEN_FOR_LAB_EXERCISES_ONLY"
    - name: AWS_ACCESS_KEY_ID
      value: "AKIAIOSFODNN7EXAMPLE"
    - name: AWS_SECRET_ACCESS_KEY
      value: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
    - name: KUBECONFIG
      value: "/tmp/cluster-kubeconfig"
---
# Vulnerable workflow ConfigMap — represents a misconfigured GitHub Actions workflow
apiVersion: v1
kind: ConfigMap
metadata:
  name: vulnerable-workflow
  namespace: dojo-sec-ci
data:
  deploy.yml: |
    name: Deploy
    on:
      pull_request_target:
        types: [opened]
    jobs:
      deploy:
        runs-on: ubuntu-latest
        steps:
        - uses: actions/checkout@v4
          with:
            ref: ${{ github.event.pull_request.head.sha }}  # VULNERABLE: checks out fork code
        - name: Greet
          run: echo "PR by ${{ github.event.pull_request.title }}"  # VULNERABLE: expression injection
        - name: Deploy
          run: kubectl apply -f manifests/
          env:
            KUBECONFIG: ${{ secrets.KUBECONFIG }}
EOF

kubectl wait --for=condition=ready pod/ci-runner -n "$NAMESPACE" --timeout=90s

echo ""
echo "CI security lab ready."
echo ""
echo "Exercises:"
echo "1. Examine the vulnerable workflow: kubectl get cm vulnerable-workflow -n $NAMESPACE -o yaml"
echo "2. Identify the two injection vulnerabilities"
echo "3. kubectl exec -n $NAMESPACE ci-runner -- env | grep -E 'GITHUB|AWS'"
echo "   (These are lab-only fake credentials)"
echo ""
echo "Fix exercises:"
echo "4. Rewrite the workflow to fix expression injection (use env: block)"
echo "5. Change pull_request_target to pull_request"
echo "6. Pin the actions/checkout to a full SHA"
