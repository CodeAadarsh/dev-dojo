#!/usr/bin/env bash
# Verifier for "Harden the Pod": secure-app has the full CKS securityContext
# and is still Ready. seccomp + runAsNonRoot accepted at pod OR container level.
set -uo pipefail

NS=dojo-cks
D=secure-app
FLAG='KUBE{restricted_securitycontext_still_runs}'
fail() { echo "✗ $1"; exit 1; }

kubectl -n "$NS" get deploy "$D" >/dev/null 2>&1 || fail "deployment '$D' not found in $NS"

jp() { kubectl -n "$NS" get deploy "$D" -o jsonpath="$1" 2>/dev/null; }
POD='{.spec.template.spec.securityContext'
CON='{.spec.template.spec.containers[0].securityContext'

RNR="$(jp "${POD}.runAsNonRoot}")$(jp "${CON}.runAsNonRoot}")"
case "$RNR" in *true*) : ;; *) fail "runAsNonRoot must be true (pod or container)";; esac

SEC="$(jp "${POD}.seccompProfile.type}")$(jp "${CON}.seccompProfile.type}")"
case "$SEC" in *RuntimeDefault*) : ;; *) fail "seccompProfile.type must be RuntimeDefault (pod or container)";; esac

ROF="$(jp "${CON}.readOnlyRootFilesystem}")"
[ "$ROF" = "true" ] || fail "container readOnlyRootFilesystem must be true (got: ${ROF:-unset})"

APE="$(jp "${CON}.allowPrivilegeEscalation}")"
[ "$APE" = "false" ] || fail "container allowPrivilegeEscalation must be false (got: ${APE:-unset})"

DROP="$(jp "${CON}.capabilities.drop}")"
case "$DROP" in *ALL*) : ;; *) fail "container capabilities.drop must include ALL (got: ${DROP:-none})";; esac

READY="$(jp '{.status.readyReplicas}')"
[ "${READY:-0}" -ge 1 ] 2>/dev/null || fail "'$D' is not Ready after hardening (readyReplicas=${READY:-0})"

echo "✓ runAsNonRoot=true  seccomp=RuntimeDefault  readOnlyRootFilesystem=true"
echo "✓ allowPrivilegeEscalation=false  capabilities.drop=ALL  readyReplicas=$READY"
echo
echo "Submit this flag:"
echo
echo "    $FLAG"
