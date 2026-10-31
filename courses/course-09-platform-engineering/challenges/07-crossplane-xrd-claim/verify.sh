#!/usr/bin/env bash
# Verifier for "Crossplane: Author an XRD, Composition & Claim".
# Checks that the XRD, Composition, and Claim are correctly authored.
# Does NOT require live provider reconciliation — checks authored objects only.
set -uo pipefail

NS=dojo-crossplane
XRD_NAME=xobjectstores.platform.dojo
COMPOSITION_NAME=objectstore-nop.platform.dojo
CLAIM_NAME=my-store
FLAG='KUBE{xrd_turns_infra_into_a_claim}'

fail() { echo "✗ $1"; exit 1; }

# ── Crossplane installed ────────────────────────────────────────────────────────
kubectl get crd compositeresourcedefinitions.apiextensions.crossplane.io >/dev/null 2>&1 \
  || fail "Crossplane CRDs not found — install Crossplane first (see brief.md)"

# ── Namespace ───────────────────────────────────────────────────────────────────
kubectl get ns "$NS" >/dev/null 2>&1 \
  || fail "namespace '$NS' is missing — run setup.sh first"

# ── XRD exists ──────────────────────────────────────────────────────────────────
kubectl get compositeresourcedefinitions.apiextensions.crossplane.io "$XRD_NAME" >/dev/null 2>&1 \
  || fail "XRD '$XRD_NAME' not found — create and apply it first"

# ── XRD Established ─────────────────────────────────────────────────────────────
ESTABLISHED=$(kubectl get compositeresourcedefinitions.apiextensions.crossplane.io "$XRD_NAME" \
  -o jsonpath='{.status.conditions[?(@.type=="Established")].status}' 2>/dev/null)
[ "$ESTABLISHED" = "True" ] \
  || fail "XRD '$XRD_NAME' is not Established (status: ${ESTABLISHED:-unknown}) — wait a few seconds and retry"

# ── XRD has correct claimNames.kind ─────────────────────────────────────────────
CLAIM_KIND=$(kubectl get compositeresourcedefinitions.apiextensions.crossplane.io "$XRD_NAME" \
  -o jsonpath='{.spec.claimNames.kind}' 2>/dev/null)
[ "$CLAIM_KIND" = "ObjectStore" ] \
  || fail "XRD '$XRD_NAME' spec.claimNames.kind is '${CLAIM_KIND:-unset}', must be 'ObjectStore'"

# ── Composition exists ──────────────────────────────────────────────────────────
kubectl get compositions.apiextensions.crossplane.io "$COMPOSITION_NAME" >/dev/null 2>&1 \
  || fail "Composition '$COMPOSITION_NAME' not found — create and apply it first"

# ── Composition compositeTypeRef.kind matches ───────────────────────────────────
COMP_KIND=$(kubectl get compositions.apiextensions.crossplane.io "$COMPOSITION_NAME" \
  -o jsonpath='{.spec.compositeTypeRef.kind}' 2>/dev/null)
[ "$COMP_KIND" = "XObjectStore" ] \
  || fail "Composition '$COMPOSITION_NAME' spec.compositeTypeRef.kind is '${COMP_KIND:-unset}', must be 'XObjectStore'"

# ── Composition compositeTypeRef.apiVersion matches ─────────────────────────────
COMP_API=$(kubectl get compositions.apiextensions.crossplane.io "$COMPOSITION_NAME" \
  -o jsonpath='{.spec.compositeTypeRef.apiVersion}' 2>/dev/null)
[ "$COMP_API" = "platform.dojo/v1alpha1" ] \
  || fail "Composition '$COMPOSITION_NAME' spec.compositeTypeRef.apiVersion is '${COMP_API:-unset}', must be 'platform.dojo/v1alpha1'"

# ── Claim exists in the target namespace ────────────────────────────────────────
kubectl -n "$NS" get objectstores.platform.dojo "$CLAIM_NAME" >/dev/null 2>&1 \
  || fail "ObjectStore Claim '$CLAIM_NAME' not found in namespace '$NS' — apply it first"

# ── Claim spec.parameters.region is set ─────────────────────────────────────────
REGION=$(kubectl -n "$NS" get objectstores.platform.dojo "$CLAIM_NAME" \
  -o jsonpath='{.spec.parameters.region}' 2>/dev/null)
[ -n "$REGION" ] \
  || fail "Claim '$CLAIM_NAME' spec.parameters.region is not set"

echo "✓ Crossplane installed    : yes"
echo "✓ namespace               : $NS"
echo "✓ XRD                     : $XRD_NAME (Established)"
echo "✓ XRD claimNames.kind     : $CLAIM_KIND"
echo "✓ Composition             : $COMPOSITION_NAME"
echo "✓ compositeTypeRef        : platform.dojo/v1alpha1 / XObjectStore"
echo "✓ Claim                   : $CLAIM_NAME (spec.parameters.region=$REGION)"
echo
echo "All Crossplane authoring checks passed. Submit this flag in the platform:"
echo
echo "    $FLAG"
