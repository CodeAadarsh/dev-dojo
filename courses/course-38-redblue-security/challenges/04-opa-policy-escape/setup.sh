#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="dojo-sec-opa"

echo "==> Setting up: OPA Policy Escape"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Check if Gatekeeper is installed — if not, simulate it
if ! kubectl get crd constrainttemplates.templates.gatekeeper.sh > /dev/null 2>&1; then
  echo "[!] Gatekeeper CRDs not found. Installing Gatekeeper..."
  kubectl apply -f https://raw.githubusercontent.com/open-policy-agent/gatekeeper/v3.16.0/deploy/gatekeeper.yaml
  echo "[*] Waiting for Gatekeeper to be ready..."
  kubectl wait --for=condition=Ready pod -l control-plane=controller-manager -n gatekeeper-system --timeout=120s
fi

# Create the ConstraintTemplate
kubectl apply -f - << 'EOF'
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: blockprivilegedcontainer
spec:
  crd:
    spec:
      names:
        kind: BlockPrivilegedContainer
  targets:
  - target: admission.k8s.gatekeeper.sh
    rego: |
      package blockprivilegedcontainer

      violation[{"msg": msg}] {
        container := input.review.object.spec.containers[_]
        container.securityContext.privileged == true
        msg := sprintf("Container '%v' must not run as privileged", [container.name])
      }

      violation[{"msg": msg}] {
        container := input.review.object.spec.initContainers[_]
        container.securityContext.privileged == true
        msg := sprintf("InitContainer '%v' must not run as privileged", [container.name])
      }
EOF

echo "[*] Waiting for ConstraintTemplate to be ready..."
sleep 5

# INTENTIONALLY BROKEN CONSTRAINT: only matches Deployments, not Pods
kubectl apply -f - << 'EOF'
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: BlockPrivilegedContainer
metadata:
  name: block-privileged-containers
spec:
  enforcementAction: deny
  match:
    kinds:
    - apiGroups: ["apps"]
      kinds: ["Deployment"]
    namespaces: ["dojo-sec-opa"]
EOF

# Plant the reward secret — readable by the verifier
FLAG_B64=$(printf '%s' 'KUBE{opa_constraints_must_be_strict}' | base64)
kubectl apply -f - << EOF
apiVersion: v1
kind: Secret
metadata:
  name: opa-reward
  namespace: $NAMESPACE
type: Opaque
data:
  flag: $FLAG_B64
EOF

echo ""
echo "==> Setup complete."
echo ""
echo "    OPA Gatekeeper is configured with a BROKEN constraint."
echo "    Current match: only Deployments in dojo-sec-opa"
echo "    Your task: fix the constraint to also block bare Pods"
echo ""
echo "    Read the constraint: kubectl get blockprivilegedcontainer block-privileged-containers -o yaml"
echo "    Edit it: kubectl edit blockprivilegedcontainer block-privileged-containers"
echo "    Then run: bash verify.sh"
