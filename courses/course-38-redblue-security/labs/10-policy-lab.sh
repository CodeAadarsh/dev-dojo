#!/usr/bin/env bash
# Lab 10: Policy as Code — deploys test targets to validate OPA/Kyverno policies
set -euo pipefail

NAMESPACE="dojo-sec-policy"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

echo "Policy as Code lab: test resources are ready to deploy"
echo "Your task: install Kyverno, then try to deploy these forbidden specs"
echo ""

# Save test manifests as ConfigMaps for reference
kubectl apply -n "$NAMESPACE" -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: test-cases
  namespace: dojo-sec-policy
data:
  # These should ALL be blocked once Kyverno is installed
  test1-privileged.yaml: |
    apiVersion: v1
    kind: Pod
    metadata:
      name: test-privileged
      namespace: dojo-sec-policy
    spec:
      containers:
      - name: c
        image: alpine:3.20
        command: [sleep, "86400"]
        securityContext:
          privileged: true

  test2-hostpath.yaml: |
    apiVersion: v1
    kind: Pod
    metadata:
      name: test-hostpath
      namespace: dojo-sec-policy
    spec:
      containers:
      - name: c
        image: alpine:3.20
        command: [sleep, "86400"]
        volumeMounts:
        - name: host
          mountPath: /host
      volumes:
      - name: host
        hostPath:
          path: /

  test3-no-limits.yaml: |
    apiVersion: v1
    kind: Pod
    metadata:
      name: test-no-limits
      namespace: dojo-sec-policy
    spec:
      containers:
      - name: c
        image: alpine:3.20
        command: [sleep, "86400"]
        # No resources.limits — should be blocked
EOF

echo ""
echo "To install Kyverno:"
echo "  helm repo add kyverno https://kyverno.github.io/kyverno/"
echo "  helm install kyverno kyverno/kyverno -n kyverno --create-namespace"
echo ""
echo "Then apply policies from Module 10 and test:"
echo "  kubectl get cm test-cases -n $NAMESPACE -o jsonpath='{.data.test1-privileged\\.yaml}' | kubectl apply -f -"
echo "  # Should fail: 'admission webhook denied the request'"
echo ""
echo "Check violations on existing resources (after applying policies with background: true):"
echo "  kubectl get policyreport -A"
