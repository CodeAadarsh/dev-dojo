#!/usr/bin/env bash
# Verifier for "Chaos Mesh Experiment".
# Checks: CRD present + PodChaos or NetworkChaos CR in dojo-chaos with valid action + namespace selector.
set -uo pipefail

NS=dojo-chaos
FLAG='KUBE{chaos_mesh_owns_the_blast_radius}'

fail() { echo "✗ $1"; exit 1; }

kubectl get ns "$NS" >/dev/null 2>&1 || fail "namespace '$NS' missing — run setup.sh first"

# Check at least one Chaos Mesh CRD is installed
HAS_PODCHAOS=0
HAS_NETCHAOS=0
kubectl get crd podchaos.chaos-mesh.org >/dev/null 2>&1 && HAS_PODCHAOS=1 || true
kubectl get crd networkchaos.chaos-mesh.org >/dev/null 2>&1 && HAS_NETCHAOS=1 || true

if [ "$HAS_PODCHAOS" -eq 0 ] && [ "$HAS_NETCHAOS" -eq 0 ]; then
  fail "Chaos Mesh CRDs not found. Install Chaos Mesh first — see brief.md for the Helm install command."
fi

# Check whether any PodChaos or NetworkChaos CRs exist in the namespace
HAS_PC_CR=0
HAS_NC_CR=0
if [ "$HAS_PODCHAOS" -eq 1 ]; then
  kubectl -n "$NS" get podchaos -o name 2>/dev/null | grep -q . && HAS_PC_CR=1 || true
fi
if [ "$HAS_NETCHAOS" -eq 1 ]; then
  kubectl -n "$NS" get networkchaos -o name 2>/dev/null | grep -q . && HAS_NC_CR=1 || true
fi

if [ "$HAS_PC_CR" -eq 0 ] && [ "$HAS_NC_CR" -eq 0 ]; then
  fail "No PodChaos or NetworkChaos CR found in namespace '$NS'. Apply your experiment CR and retry."
fi

# Inspect the first CR found (prefer PodChaos over NetworkChaos)
if [ "$HAS_PC_CR" -eq 1 ]; then
  CR_KIND=PodChaos
  CR_NAME=$(kubectl -n "$NS" get podchaos -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  ACTION=$(kubectl -n "$NS" get podchaos -o jsonpath='{.items[0].spec.action}' 2>/dev/null)
  SEL_NS=$(kubectl -n "$NS" get podchaos -o jsonpath='{.items[0].spec.selector.namespaces[0]}' 2>/dev/null)
else
  CR_KIND=NetworkChaos
  CR_NAME=$(kubectl -n "$NS" get networkchaos -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  ACTION=$(kubectl -n "$NS" get networkchaos -o jsonpath='{.items[0].spec.action}' 2>/dev/null)
  SEL_NS=$(kubectl -n "$NS" get networkchaos -o jsonpath='{.items[0].spec.selector.namespaces[0]}' 2>/dev/null)
fi

[ -n "${ACTION:-}" ] || fail "$CR_KIND '${CR_NAME:-?}': spec.action is empty. Set it to 'pod-kill'/'pod-failure' (PodChaos) or 'delay'/'loss' (NetworkChaos)."
[ "${SEL_NS:-}" = "$NS" ] || fail "$CR_KIND '${CR_NAME:-?}': spec.selector.namespaces[0] must be '$NS' (found: '${SEL_NS:-not set}'). Scope the blast radius to the correct namespace."

echo "✓ Chaos Mesh CRD present    : $CR_KIND (chaos-mesh.org/v1alpha1)"
echo "✓ CR name                   : $CR_NAME"
echo "✓ spec.action               : $ACTION"
echo "✓ selector.namespaces[0]    : $SEL_NS"
echo
echo "Chaos experiment CR is correctly authored. Submit this flag:"
echo
echo "    $FLAG"
