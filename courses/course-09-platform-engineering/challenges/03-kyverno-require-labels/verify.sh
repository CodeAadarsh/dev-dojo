#!/usr/bin/env bash
# Verifier for "Kyverno: Require Pod Labels".
# Checks that a ClusterPolicy named require-pod-labels exists in Enforce mode,
# targets Pod resources in dojo-policy, and actually denies unlabelled pods.
set -uo pipefail

NS=dojo-policy
POLICY=require-pod-labels
FLAG='KUBE{kyverno_labels_or_bust}'

fail() { echo "✗ $1"; exit 1; }

# ── Namespace ───────────────────────────────────────────────────────────────────
kubectl get ns "$NS" >/dev/null 2>&1 \
  || fail "namespace '$NS' is missing — run setup.sh first"

# ── Kyverno installed ───────────────────────────────────────────────────────────
kubectl get ns kyverno >/dev/null 2>&1 \
  || fail "Kyverno not installed (namespace 'kyverno' missing) — install it first (see brief.md)"

# ── ClusterPolicy exists ────────────────────────────────────────────────────────
kubectl get clusterpolicy "$POLICY" >/dev/null 2>&1 \
  || fail "ClusterPolicy '$POLICY' not found — create it first"

# ── Enforce mode ────────────────────────────────────────────────────────────────
ACTION=$(kubectl get clusterpolicy "$POLICY" \
  -o jsonpath='{.spec.validationFailureAction}' 2>/dev/null)
[ "$ACTION" = "Enforce" ] \
  || fail "ClusterPolicy '$POLICY' validationFailureAction is '${ACTION:-unset}', must be 'Enforce'"

# ── At least one rule targets Pod resources ─────────────────────────────────────
RULE_COUNT=$(kubectl get clusterpolicy "$POLICY" \
  -o jsonpath='{.spec.rules}' 2>/dev/null | grep -c '"Pod"' || true)
[ "${RULE_COUNT:-0}" -ge 1 ] \
  || fail "ClusterPolicy '$POLICY' has no rule matching 'Pod' kind"

# ── Live admission test: unlabelled pod must be denied ──────────────────────────
# Use --dry-run=server so the admission webhook fires but nothing is persisted
DENY_OUTPUT=$(kubectl -n "$NS" run verify-bad-pod \
  --image=nginx:1.27-alpine \
  --restart=Never \
  --dry-run=server 2>&1 || true)
echo "$DENY_OUTPUT" | grep -qi "denied\|admission webhook\|forbidden" \
  || fail "unlabelled pod was NOT denied by the policy — is the ClusterPolicy in Enforce mode and targeting namespace '$NS'?"

# ── Live admission test: labelled pod must be admitted ──────────────────────────
ALLOW_OUTPUT=$(kubectl -n "$NS" run verify-good-pod \
  --image=nginx:1.27-alpine \
  --labels="app=verify,team=dojo" \
  --restart=Never \
  --dry-run=server 2>&1 || true)
echo "$ALLOW_OUTPUT" | grep -qi "denied\|forbidden" \
  && fail "pod with valid labels was denied — check the policy pattern is not overly restrictive"

echo "✓ namespace            : $NS"
echo "✓ Kyverno installed    : yes"
echo "✓ ClusterPolicy        : $POLICY"
echo "✓ failureAction        : Enforce"
echo "✓ Pod rule present     : yes"
echo "✓ unlabelled pod       : denied (admission webhook fired)"
echo "✓ labelled pod         : admitted"
echo
echo "All policy checks passed. Submit this flag in the platform:"
echo
echo "    $FLAG"
