#!/usr/bin/env bash
# Verifier for "Lock the Namespace". Confirms the namespace enforces the
# built-in restricted Pod Security Standard AND a compliant 'api' pod is
# Running. Prints the flag only when every check passes. 0 = solved, 1 = not yet.
set -uo pipefail

NS=dojo-psa
DEPLOY=api
FLAG='KUBE{restricted_psa_locks_the_namespace}'

fail() { echo "✗ $1"; exit 1; }

# Read a securityContext field from the container, falling back to the pod-level
# securityContext (where runAsNonRoot / seccompProfile may legitimately live).
csc() { kubectl -n "$NS" get deploy "$DEPLOY" -o jsonpath="{.spec.template.spec.containers[0].securityContext.$1}" 2>/dev/null; }
psc() { kubectl -n "$NS" get deploy "$DEPLOY" -o jsonpath="{.spec.template.spec.securityContext.$1}" 2>/dev/null; }

kubectl get ns "$NS" >/dev/null 2>&1 || fail "namespace '$NS' is missing — run setup.sh first"

# --- namespace labels ---------------------------------------------------------
ENFORCE=$(kubectl get ns "$NS" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>/dev/null)
[ "$ENFORCE" = "restricted" ] || fail "namespace label pod-security.kubernetes.io/enforce must be 'restricted' (found: ${ENFORCE:-unset})"

WARN=$(kubectl get ns "$NS" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/warn}' 2>/dev/null)
[ "$WARN" = "restricted" ] || fail "namespace label pod-security.kubernetes.io/warn must be 'restricted' (found: ${WARN:-unset})"

AUDIT=$(kubectl get ns "$NS" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/audit}' 2>/dev/null)
[ "$AUDIT" = "restricted" ] || fail "namespace label pod-security.kubernetes.io/audit must be 'restricted' (found: ${AUDIT:-unset})"

# --- workload exists ----------------------------------------------------------
kubectl -n "$NS" get deploy "$DEPLOY" >/dev/null 2>&1 || fail "Deployment '$DEPLOY' not found in $NS"

# --- restricted securityContext fields ---------------------------------------
RANR=$(csc runAsNonRoot); [ -n "$RANR" ] || RANR=$(psc runAsNonRoot)
[ "$RANR" = "true" ] || fail "runAsNonRoot must be true (container or pod securityContext) — found: ${RANR:-unset}"

APE=$(csc allowPrivilegeEscalation)
[ "$APE" = "false" ] || fail "allowPrivilegeEscalation must be false on the container — found: ${APE:-unset}"

DROP=$(csc 'capabilities.drop')
echo "$DROP" | grep -q 'ALL' || fail "container must drop ALL capabilities (securityContext.capabilities.drop: [\"ALL\"]) — found: ${DROP:-none}"

SECCOMP=$(csc 'seccompProfile.type'); [ -n "$SECCOMP" ] || SECCOMP=$(psc 'seccompProfile.type')
[ "$SECCOMP" = "RuntimeDefault" ] || fail "seccompProfile.type must be RuntimeDefault (container or pod) — found: ${SECCOMP:-unset}"

PRIV=$(csc privileged)
[ "$PRIV" != "true" ] || fail "container is still privileged: true — remove it"

# --- the real proof: a compliant pod was admitted and is Ready ----------------
READY=$(kubectl -n "$NS" get deploy "$DEPLOY" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
if ! [ "${READY:-0}" -ge 1 ] 2>/dev/null; then
  fail "no Ready pods (found: ${READY:-0}) — under enforce=restricted a non-compliant pod is REJECTED; check 'kubectl -n $NS rollout status deploy/$DEPLOY' and 'kubectl -n $NS get events'"
fi

echo "✓ enforce=restricted label  : yes"
echo "✓ warn=restricted label     : yes"
echo "✓ audit=restricted label    : yes"
echo "✓ runAsNonRoot              : true"
echo "✓ allowPrivilegeEscalation  : false"
echo "✓ capabilities dropped      : ALL"
echo "✓ seccompProfile            : RuntimeDefault"
echo "✓ not privileged            : yes"
echo "✓ compliant pods Ready      : $READY"
echo
echo "The namespace is locked and the workload complies. Submit this flag in the platform:"
echo
echo "    $FLAG"
