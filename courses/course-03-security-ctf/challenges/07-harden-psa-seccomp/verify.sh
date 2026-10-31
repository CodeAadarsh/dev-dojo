#!/usr/bin/env bash
# Verifier for "Restricted By Default". Passes only when the namespace enforces
# the Pod Security Admission 'restricted' profile AND at least one Running pod in
# it is actually compliant (non-root, drop ALL caps, no privilege escalation,
# seccomp RuntimeDefault). Exit 0 = solved, 1 = not yet.
set -uo pipefail

NS=dojo-hardpsa
FLAG='KUBE{restricted_by_default_closes_the_escape}'

fail() { echo "✗ $1"; exit 1; }

kubectl get ns "$NS" >/dev/null 2>&1 || fail "namespace '$NS' is missing — run setup.sh first"

# --- Check 1: namespace enforces restricted via Pod Security Admission
ENFORCE=$(kubectl get ns "$NS" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>/dev/null)
[ "$ENFORCE" = "restricted" ] || fail "namespace needs label pod-security.kubernetes.io/enforce=restricted (found: ${ENFORCE:-unset})"

# --- Check 2: at least one Running pod is restricted-compliant
PODS=$(kubectl -n "$NS" get pods -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
[ -n "$PODS" ] || fail "no pods in '$NS' — rebuild the workload so a compliant pod runs"

COMPLIANT=""
for p in $PODS; do
  phase=$(kubectl -n "$NS" get pod "$p" -o jsonpath='{.status.phase}' 2>/dev/null)
  [ "$phase" = "Running" ] || continue

  ape=$(kubectl -n "$NS" get pod "$p" -o jsonpath='{.spec.containers[0].securityContext.allowPrivilegeEscalation}' 2>/dev/null)
  [ "$ape" = "false" ] || continue

  drop=$(kubectl -n "$NS" get pod "$p" -o jsonpath='{.spec.containers[0].securityContext.capabilities.drop[*]}' 2>/dev/null)
  case " $drop " in *" ALL "*) ;; *) continue ;; esac

  # runAsNonRoot may be set at pod level or container level
  rnn_pod=$(kubectl -n "$NS" get pod "$p" -o jsonpath='{.spec.securityContext.runAsNonRoot}' 2>/dev/null)
  rnn_ctr=$(kubectl -n "$NS" get pod "$p" -o jsonpath='{.spec.containers[0].securityContext.runAsNonRoot}' 2>/dev/null)
  [ "$rnn_pod" = "true" ] || [ "$rnn_ctr" = "true" ] || continue

  # seccompProfile RuntimeDefault may be set at pod level or container level
  sec_pod=$(kubectl -n "$NS" get pod "$p" -o jsonpath='{.spec.securityContext.seccompProfile.type}' 2>/dev/null)
  sec_ctr=$(kubectl -n "$NS" get pod "$p" -o jsonpath='{.spec.containers[0].securityContext.seccompProfile.type}' 2>/dev/null)
  [ "$sec_pod" = "RuntimeDefault" ] || [ "$sec_ctr" = "RuntimeDefault" ] || continue

  COMPLIANT="$p"
  break
done
[ -n "$COMPLIANT" ] || fail "no Running pod is restricted-compliant (need runAsNonRoot=true, allowPrivilegeEscalation=false, capabilities.drop=[ALL], seccompProfile.type=RuntimeDefault)"

echo "✓ namespace enforce profile : restricted"
echo "✓ compliant Running pod     : $COMPLIANT"
echo "    allowPrivilegeEscalation : false"
echo "    capabilities.drop        : ALL"
echo "    runAsNonRoot             : true"
echo "    seccompProfile.type      : RuntimeDefault"
echo
echo "Namespace is restricted-by-default and the workload complies. Submit this flag:"
echo
echo "    $FLAG"
