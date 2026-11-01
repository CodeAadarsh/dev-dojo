#!/usr/bin/env bash
# Verifier for "Sealed Secrets: Commit a Secret Safely".
# Checks:
#   1. A SealedSecret (bitnami.com) named dojo-app-creds exists in dojo-sealed
#   2. A native Secret named dojo-app-creds was produced by the controller in dojo-sealed
set -uo pipefail

NS=dojo-sealed
FLAG='KUBE{sealed_secret_only_cluster_unseals}'

fail() { echo "✗ $1"; exit 1; }

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Targeting your current context anyway."
fi

# ── 1. SealedSecret CRD is available ─────────────────────────────────────────
echo "--> checking SealedSecret CRD..."
kubectl api-resources --api-group=bitnami.com 2>/dev/null | grep -q sealedsecret \
  || fail "SealedSecret CRD not found (bitnami.com). Is the Sealed Secrets controller installed? Run setup.sh."

# ── 2. SealedSecret object exists in dojo-sealed ─────────────────────────────
echo "--> checking SealedSecret 'dojo-app-creds' in namespace ${NS}..."
kubectl get sealedsecret dojo-app-creds -n "$NS" >/dev/null 2>&1 \
  || fail "SealedSecret 'dojo-app-creds' not found in namespace '${NS}'. Apply sealed-secret.yaml and retry."

# ── 3. SealedSecret has correct API group ─────────────────────────────────────
SS_GROUP=$(kubectl get sealedsecret dojo-app-creds -n "$NS" \
  -o jsonpath='{.apiVersion}' 2>/dev/null)
echo "$SS_GROUP" | grep -q 'bitnami.com' \
  || fail "SealedSecret apiVersion must contain 'bitnami.com', got: ${SS_GROUP}"

# ── 4. Controller produced the native Secret ──────────────────────────────────
echo "--> checking that the controller unsealed 'dojo-app-creds' into a Secret..."
# Give the controller a few seconds to reconcile if the SealedSecret was just applied
for i in $(seq 1 10); do
  if kubectl get secret dojo-app-creds -n "$NS" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

kubectl get secret dojo-app-creds -n "$NS" >/dev/null 2>&1 \
  || fail "Secret 'dojo-app-creds' was not found in '${NS}' — the controller may not have reconciled yet. Check: kubectl describe sealedsecret dojo-app-creds -n ${NS}"

# ── 5. Secret was created by the sealed-secrets controller (owner reference) ──
echo "--> verifying Secret ownership..."
OWNER=$(kubectl get secret dojo-app-creds -n "$NS" \
  -o jsonpath='{.metadata.ownerReferences[0].kind}' 2>/dev/null)
[ "$OWNER" = "SealedSecret" ] \
  || fail "Secret 'dojo-app-creds' exists but was not created by the Sealed Secrets controller (ownerReference.kind != 'SealedSecret'). Did you manually apply a plaintext Secret instead of kubeseal output?"

# ── All checks passed ─────────────────────────────────────────────────────────
echo
echo "All checks passed. Submit this flag in the platform:"
echo
echo "    $FLAG"
