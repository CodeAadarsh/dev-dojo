#!/usr/bin/env bash
# Verifier for "External Secrets Operator: Declare a Sync".
# Checks that a SecretStore and ExternalSecret exist in namespace dojo-secrets
# with the required fields — does not require the fake-provider sync to complete.
set -uo pipefail

NS=dojo-secrets
FLAG='KUBE{external_secret_operator_synced}'

fail() { echo "✗ $1"; exit 1; }

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Targeting your current context anyway."
fi

# ── 1. SecretStore exists ─────────────────────────────────────────────────────
echo "--> checking SecretStore 'dojo-store' in namespace ${NS}..."
kubectl get secretstore dojo-store -n "$NS" >/dev/null 2>&1 \
  || fail "SecretStore 'dojo-store' not found in namespace '${NS}'. Apply it and retry."

# ── 2. SecretStore has correct API group ──────────────────────────────────────
SS_GROUP=$(kubectl get secretstore dojo-store -n "$NS" \
  -o jsonpath='{.apiVersion}' 2>/dev/null) \
  || fail "Could not read SecretStore apiVersion"
echo "$SS_GROUP" | grep -q 'external-secrets.io' \
  || fail "SecretStore apiVersion must be 'external-secrets.io/v1beta1', got: ${SS_GROUP}"

# ── 3. SecretStore uses fake provider ─────────────────────────────────────────
echo "--> checking SecretStore provider is 'fake'..."
SS_FAKE=$(kubectl get secretstore dojo-store -n "$NS" \
  -o jsonpath='{.spec.provider.fake}' 2>/dev/null)
[ -n "$SS_FAKE" ] \
  || fail "SecretStore 'dojo-store' must use the 'fake' provider (spec.provider.fake)"

# ── 4. ExternalSecret exists ──────────────────────────────────────────────────
echo "--> checking ExternalSecret 'dojo-app-secret' in namespace ${NS}..."
kubectl get externalsecret dojo-app-secret -n "$NS" >/dev/null 2>&1 \
  || fail "ExternalSecret 'dojo-app-secret' not found in namespace '${NS}'. Apply it and retry."

# ── 5. ExternalSecret references correct store ────────────────────────────────
echo "--> checking ExternalSecret secretStoreRef..."
ES_STORE=$(kubectl get externalsecret dojo-app-secret -n "$NS" \
  -o jsonpath='{.spec.secretStoreRef.name}' 2>/dev/null)
[ "$ES_STORE" = "dojo-store" ] \
  || fail "ExternalSecret spec.secretStoreRef.name must be 'dojo-store', got: ${ES_STORE}"

ES_STORE_KIND=$(kubectl get externalsecret dojo-app-secret -n "$NS" \
  -o jsonpath='{.spec.secretStoreRef.kind}' 2>/dev/null)
[ "$ES_STORE_KIND" = "SecretStore" ] \
  || fail "ExternalSecret spec.secretStoreRef.kind must be 'SecretStore', got: ${ES_STORE_KIND}"

# ── 6. ExternalSecret has correct target name ────────────────────────────────
echo "--> checking ExternalSecret target name..."
ES_TARGET=$(kubectl get externalsecret dojo-app-secret -n "$NS" \
  -o jsonpath='{.spec.target.name}' 2>/dev/null)
[ "$ES_TARGET" = "dojo-synced-app" ] \
  || fail "ExternalSecret spec.target.name must be 'dojo-synced-app', got: ${ES_TARGET}"

# ── 7. ExternalSecret has a data mapping with remoteRef ──────────────────────
echo "--> checking ExternalSecret data mapping..."
ES_SECRET_KEY=$(kubectl get externalsecret dojo-app-secret -n "$NS" \
  -o jsonpath='{.spec.data[0].secretKey}' 2>/dev/null)
[ "$ES_SECRET_KEY" = "api_key" ] \
  || fail "ExternalSecret spec.data[0].secretKey must be 'api_key', got: ${ES_SECRET_KEY}"

ES_REMOTE_KEY=$(kubectl get externalsecret dojo-app-secret -n "$NS" \
  -o jsonpath='{.spec.data[0].remoteRef.key}' 2>/dev/null)
[ "$ES_REMOTE_KEY" = "/dojo/app/api-key" ] \
  || fail "ExternalSecret spec.data[0].remoteRef.key must be '/dojo/app/api-key', got: ${ES_REMOTE_KEY}"

# ── All checks passed ─────────────────────────────────────────────────────────
echo
echo "All checks passed. Submit this flag in the platform:"
echo
echo "    $FLAG"
