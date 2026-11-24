#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="dojo-sec-gauntlet"

echo "==> Setting up: Admission Gauntlet"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Create the high-priv SA that attack #5 targets (it will exist, but pods using it should be blocked)
kubectl apply -f - << EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: dojo-sec-gauntlet-admin
  namespace: $NAMESPACE
EOF

# Check if Gatekeeper is installed
if ! kubectl get crd constrainttemplates.templates.gatekeeper.sh > /dev/null 2>&1; then
  echo "[!] Installing Gatekeeper..."
  kubectl apply -f https://raw.githubusercontent.com/open-policy-agent/gatekeeper/v3.16.0/deploy/gatekeeper.yaml
  echo "[*] Waiting for Gatekeeper..."
  kubectl wait --for=condition=Ready pod -l control-plane=controller-manager -n gatekeeper-system --timeout=180s
fi

# Check if Kyverno is installed
if ! kubectl get crd clusterpolicies.kyverno.io > /dev/null 2>&1; then
  echo "[!] Installing Kyverno..."
  kubectl apply -f https://github.com/kyverno/kyverno/releases/download/v1.12.0/install.yaml
  echo "[*] Waiting for Kyverno..."
  kubectl wait --for=condition=Ready pod -l app.kubernetes.io/component=admission-controller -n kyverno --timeout=180s
fi

# Plant the flag
FLAG_B64=$(printf '%s' 'KUBE{five_policies_block_five_attacks}' | base64)
kubectl apply -f - << EOF
apiVersion: v1
kind: Secret
metadata:
  name: gauntlet-reward
  namespace: $NAMESPACE
type: Opaque
data:
  flag: $FLAG_B64
EOF

echo ""
echo "==> Setup complete. Gatekeeper and Kyverno are installed."
echo ""
echo "    Namespace: $NAMESPACE"
echo "    Your task: write and apply 5 policies (see brief.md)"
echo "    Then run: bash verify.sh"
echo ""
echo "    Policy deployment guide:"
echo "    1. OPA ConstraintTemplate + Constraint for privileged and hostPath"
echo "    2. Kyverno ClusterPolicy for resource limits, no-latest-tag, and banned SA"
