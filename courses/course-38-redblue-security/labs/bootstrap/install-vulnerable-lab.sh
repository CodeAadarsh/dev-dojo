#!/usr/bin/env bash
# Bootstrap script: installs cluster-wide prerequisites for course-38
# Run once before any challenge setup.sh
set -euo pipefail

echo "==> course-38 bootstrap: Red Team / Blue Team Security Lab"
echo ""

# --- Verify cluster access ---
kubectl cluster-info --request-timeout=5s > /dev/null 2>&1 || {
  echo "ERROR: Cannot reach cluster. Start kind first:"
  echo "  kind create cluster --name dojo"
  exit 1
}
echo "[OK] Cluster reachable"

# --- Install OPA Gatekeeper ---
echo ""
echo "--> Installing OPA Gatekeeper..."
GATEKEEPER_VERSION="v3.14.0"
kubectl apply -f "https://raw.githubusercontent.com/open-policy-agent/gatekeeper/${GATEKEEPER_VERSION}/deploy/gatekeeper.yaml" 2>/dev/null || \
  echo "[SKIP] Gatekeeper already installed or unreachable (challenges/04 and 12 need it)"

# Wait for gatekeeper controller-manager
kubectl rollout status deployment/gatekeeper-controller-manager -n gatekeeper-system \
  --timeout=90s 2>/dev/null && echo "[OK] Gatekeeper ready" || \
  echo "[WARN] Gatekeeper not ready — challenges 04 and 12 may fail"

# --- Install Kyverno ---
echo ""
echo "--> Installing Kyverno..."
KYVERNO_VERSION="v1.11.1"
kubectl apply -f "https://github.com/kyverno/kyverno/releases/download/${KYVERNO_VERSION}/install.yaml" 2>/dev/null || \
  echo "[SKIP] Kyverno already installed or unreachable (challenge 12 needs it)"

kubectl rollout status deployment/kyverno -n kyverno \
  --timeout=90s 2>/dev/null && echo "[OK] Kyverno ready" || \
  echo "[WARN] Kyverno not ready — challenge 12 may fail"

# --- Install cert-manager (needed for mTLS challenge) ---
echo ""
echo "--> Installing cert-manager..."
CERTMGR_VERSION="v1.14.3"
kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERTMGR_VERSION}/cert-manager.yaml" 2>/dev/null || \
  echo "[SKIP] cert-manager already installed or unreachable (challenge 13 uses it)"

kubectl rollout status deployment/cert-manager -n cert-manager \
  --timeout=90s 2>/dev/null && echo "[OK] cert-manager ready" || \
  echo "[WARN] cert-manager not ready — challenge 13 may fail"

# --- Create shared dojo-sec namespace for course infrastructure ---
kubectl create namespace dojo-sec --dry-run=client -o yaml | kubectl apply -f -
echo "[OK] dojo-sec namespace ready"

# --- Verify NetworkPolicy support ---
echo ""
echo "--> Checking NetworkPolicy enforcement..."
CNI=$(kubectl get pods -n kube-system -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -E 'calico|cilium|weave|flannel' | head -1)
if [ -n "$CNI" ]; then
  echo "[OK] CNI detected: $CNI"
else
  echo "[WARN] No known CNI detected. NetworkPolicy may not be enforced."
  echo "       kind default (kindnet) does not enforce NetworkPolicy."
  echo "       For NetworkPolicy labs, use: kind create cluster --config kind-calico.yaml"
fi

# --- Summary ---
echo ""
echo "==> Bootstrap complete."
echo ""
echo "    Course 38 — Red Team / Blue Team Security"
echo "    Challenges: 01–15 (run each challenge's setup.sh individually)"
echo "    Recommended order: 01 → 02 → 03 → 04 → ... → 15"
echo ""
echo "    Cluster-wide components installed:"
echo "      - OPA Gatekeeper  (challenges 04, 12)"
echo "      - Kyverno         (challenge 12)"
echo "      - cert-manager    (challenge 13)"
echo ""
echo "    Start with: cd challenges/01-imds-credential-theft && bash setup.sh"
