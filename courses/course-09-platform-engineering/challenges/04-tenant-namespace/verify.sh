#!/usr/bin/env bash
# Verifier for "Provision a Tenant Namespace".
# Checks that dojo-tenant-a has a ResourceQuota (with pods/cpu/memory hard limits),
# a LimitRange, and a RoleBinding binding SA tenant-operator to the edit ClusterRole.
set -uo pipefail

NS=dojo-tenant-a
FLAG='KUBE{tenant_namespace_quota_and_rbac}'

fail() { echo "✗ $1"; exit 1; }

kubectl get ns "$NS" >/dev/null 2>&1 || fail "namespace '$NS' is missing — run setup.sh first"

# ── ResourceQuota ──────────────────────────────────────────────────────────────
RQ_NAME=$(kubectl -n "$NS" get resourcequota -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -n "$RQ_NAME" ] || fail "no ResourceQuota found in namespace '$NS'"

RQ_PODS=$(kubectl -n "$NS" get resourcequota "$RQ_NAME" -o jsonpath='{.spec.hard.pods}' 2>/dev/null)
[ -n "$RQ_PODS" ] || fail "ResourceQuota '$RQ_NAME' must include a 'pods' hard limit"

RQ_CPU=$(kubectl -n "$NS" get resourcequota "$RQ_NAME" -o jsonpath='{.spec.hard.cpu}' 2>/dev/null)
[ -n "$RQ_CPU" ] || fail "ResourceQuota '$RQ_NAME' must include a 'cpu' hard limit"

RQ_MEM=$(kubectl -n "$NS" get resourcequota "$RQ_NAME" -o jsonpath='{.spec.hard.memory}' 2>/dev/null)
[ -n "$RQ_MEM" ] || fail "ResourceQuota '$RQ_NAME' must include a 'memory' hard limit"

# ── LimitRange ─────────────────────────────────────────────────────────────────
LR_NAME=$(kubectl -n "$NS" get limitrange -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -n "$LR_NAME" ] || fail "no LimitRange found in namespace '$NS'"

# ── RoleBinding ────────────────────────────────────────────────────────────────
RB_NAME=$(kubectl -n "$NS" get rolebinding -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -n "$RB_NAME" ] || fail "no RoleBinding found in namespace '$NS'"

ROLE_REF=$(kubectl -n "$NS" get rolebinding "$RB_NAME" -o jsonpath='{.roleRef.name}' 2>/dev/null)
[ "$ROLE_REF" = "edit" ] || fail "RoleBinding '$RB_NAME' must reference roleRef.name 'edit' (found: ${ROLE_REF:-none})"

SUBJ_KIND=$(kubectl -n "$NS" get rolebinding "$RB_NAME" -o jsonpath='{.subjects[0].kind}' 2>/dev/null)
[ "$SUBJ_KIND" = "ServiceAccount" ] || fail "RoleBinding '$RB_NAME' subject must be a ServiceAccount (found kind: ${SUBJ_KIND:-none})"

SUBJ_NAME=$(kubectl -n "$NS" get rolebinding "$RB_NAME" -o jsonpath='{.subjects[0].name}' 2>/dev/null)
[ "$SUBJ_NAME" = "tenant-operator" ] || fail "RoleBinding '$RB_NAME' must bind ServiceAccount 'tenant-operator' (found: ${SUBJ_NAME:-none})"

echo "✓ namespace       : $NS"
echo "✓ ResourceQuota   : $RQ_NAME (pods=$RQ_PODS, cpu=$RQ_CPU, memory=$RQ_MEM)"
echo "✓ LimitRange      : $LR_NAME"
echo "✓ RoleBinding     : $RB_NAME → roleRef=edit, subject=ServiceAccount/tenant-operator"
echo
echo "All namespace governance checks passed. Submit this flag in the platform:"
echo
echo "    $FLAG"
