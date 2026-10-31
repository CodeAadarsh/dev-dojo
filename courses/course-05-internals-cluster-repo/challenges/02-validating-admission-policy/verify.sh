#!/usr/bin/env bash
# Verifier for "Ban the Latest". Confirms a ValidatingAdmissionPolicy + binding
# exist AND actually reject :latest while allowing a pinned tag, then prints the
# flag. Exit 0 = solved, 1 = not yet. Uses --dry-run=server so admission runs
# for real but nothing is persisted.
set -uo pipefail

NS=dojo-admission
FLAG='KUBE{cel_policy_bans_the_latest_tag}'

fail() { echo "✗ $1"; exit 1; }

kubectl get ns "$NS" >/dev/null 2>&1 \
  || fail "namespace '$NS' is missing — run setup.sh first"

# 1) A ValidatingAdmissionPolicy must exist.
VAP=$(kubectl get validatingadmissionpolicy -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
[ -n "$VAP" ] \
  || fail "no ValidatingAdmissionPolicy found — create one (see brief/solution)"

# 2) A ValidatingAdmissionPolicyBinding must exist (policy alone is inert).
VAPB=$(kubectl get validatingadmissionpolicybinding -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
[ -n "$VAPB" ] \
  || fail "no ValidatingAdmissionPolicyBinding found — a policy with no binding enforces nothing"

# Clean up any pods left by a non-dry-run attempt so AlreadyExists can't skew results.
kubectl -n "$NS" delete pod bad good --ignore-not-found --wait=false >/dev/null 2>&1

# 3) A :latest image must be REJECTED (command must FAIL).
if kubectl -n "$NS" run bad --image=nginx:latest --restart=Never --dry-run=server >/dev/null 2>&1; then
  fail "a Pod using nginx:latest was ADMITTED — your policy is not rejecting :latest / untagged images in $NS"
fi

# 4) A pinned tag must be ADMITTED (command must SUCCEED).
kubectl -n "$NS" run good --image=nginx:1.27-alpine --restart=Never --dry-run=server >/dev/null 2>&1 \
  || fail "a Pod using nginx:1.27-alpine was REJECTED — your policy is too strict; it must allow pinned tags"

echo "✓ ValidatingAdmissionPolicy        : $VAP"
echo "✓ ValidatingAdmissionPolicyBinding : $VAPB"
echo "✓ nginx:latest in $NS              : REJECTED (correct)"
echo "✓ nginx:1.27-alpine in $NS         : ADMITTED (correct)"
echo
echo "All checks passed. Submit this flag in the platform:"
echo
echo "    $FLAG"
