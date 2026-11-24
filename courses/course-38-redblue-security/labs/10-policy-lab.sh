#!/usr/bin/env bash
# Module 10 — Policy as Code Lab
# Installs OPA Gatekeeper + Kyverno with deliberately weak policies to bypass
set -euo pipefail

NS="dojo-lab-policy"

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

# Install Kyverno if not present
if ! helm list -n kyverno | grep -q "^kyverno"; then
  echo "Installing Kyverno..."
  helm repo add kyverno https://kyverno.github.io/kyverno/ --force-update
  helm repo update
  helm install kyverno kyverno/kyverno \
    --namespace kyverno --create-namespace \
    --set admissionController.replicas=1 \
    --wait --timeout=5m
  echo "Kyverno installed."
else
  echo "Kyverno already installed."
fi

# Install OPA Gatekeeper if not present
if ! kubectl get deployment -n gatekeeper-system gatekeeper-controller-manager >/dev/null 2>&1; then
  echo "Installing OPA Gatekeeper..."
  kubectl apply -f https://raw.githubusercontent.com/open-policy-agent/gatekeeper/v3.17.0/deploy/gatekeeper.yaml
  kubectl wait deployment gatekeeper-controller-manager \
    -n gatekeeper-system --for=condition=Available --timeout=5m
  echo "OPA Gatekeeper installed."
else
  echo "OPA Gatekeeper already installed."
fi

# Deliberately weak Kyverno policy (Audit mode — doesn't block, just logs)
kubectl apply -f - <<EOF
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: weak-require-labels
  annotations:
    policies.kyverno.io/description: "Deliberately set to Audit — doesn't enforce"
spec:
  validationFailureAction: Audit
  rules:
  - name: check-team-label
    match:
      any:
      - resources:
          kinds: [Pod]
          namespaces: ["$NS"]
    validate:
      message: "Pod must have a 'team' label (but this is Audit mode so it won't block)"
      pattern:
        metadata:
          labels:
            team: "?*"
---
# A pod that violates the policy but gets through because it's Audit mode
apiVersion: v1
kind: Pod
metadata:
  name: policy-violator
  namespace: $NS
  labels:
    app: violator
    # team label MISSING — should be blocked but isn't because policy is Audit
spec:
  containers:
  - name: c
    image: alpine:3.20
    command: ["sh", "-c", "sleep 86400"]
    securityContext:
      privileged: false
    resources:
      limits:
        cpu: "100m"
        memory: "64Mi"
  restartPolicy: Always
EOF

echo "Policy lab ready. Namespace: $NS"
echo ""
echo "Exercise 1 — Audit vs Enforce:"
echo "  The 'weak-require-labels' policy is in Audit mode."
echo "  Deploy a pod without the 'team' label — it passes admission."
echo "  Change to Enforce mode: kubectl patch clusterpolicy weak-require-labels -p '{\"spec\":{\"validationFailureAction\":\"Enforce\"}}'"
echo "  Try again — now it's blocked."
echo ""
echo "Exercise 2 — Write a policy that BLOCKS privileged containers in $NS:"
echo "  kubectl apply -f your-privileged-policy.yaml"
echo "  Verify: kubectl apply --dry-run=server -f privileged-pod.yaml  (should fail)"
echo ""
echo "Exercise 3 — OPA Gatekeeper ConstraintTemplate:"
echo "  Write a ConstraintTemplate in Rego that rejects pods without resource limits."
