#!/usr/bin/env bash
# Verifier for "Teach the API a New Word". Checks that a Widget CRD (group
# dojo.local) is Established with a schema requiring spec.size, and that at
# least one Widget custom resource exists in dojo-crd. Prints the flag on pass.
set -uo pipefail

NS=dojo-crd
FLAG='KUBE{crd_teaches_the_api_a_new_kind}'

fail() { echo "✗ $1"; exit 1; }

# 1. a CRD in group dojo.local whose kind is Widget
CRD=$(kubectl get crd -o jsonpath='{range .items[?(@.spec.group=="dojo.local")]}{.metadata.name}{" "}{.spec.names.kind}{"\n"}{end}' 2>/dev/null | awk '$2=="Widget"{print $1}' | head -1)
[ -n "$CRD" ] || fail "no CRD with group 'dojo.local' and kind 'Widget' found — apply your CRD first"

# 2. it must be Established
ESTAB=$(kubectl get crd "$CRD" -o jsonpath='{range .status.conditions[?(@.type=="Established")]}{.status}{end}' 2>/dev/null)
[ "$ESTAB" = "True" ] || fail "CRD '$CRD' is not Established yet (status: ${ESTAB:-unknown}) — give it a moment"

# 3. schema must require spec.size
REQ=$(kubectl get crd "$CRD" -o jsonpath='{.spec.versions[0].schema.openAPIV3Schema.properties.spec.required}' 2>/dev/null)
echo "$REQ" | grep -q 'size' || fail "the schema must require spec.size (found required: ${REQ:-none})"

# 4. at least one Widget CR in the namespace
PLURAL=$(kubectl get crd "$CRD" -o jsonpath='{.spec.names.plural}' 2>/dev/null)
COUNT=$(kubectl -n "$NS" get "${PLURAL}.dojo.local" -o name 2>/dev/null | grep -c . )
[ "${COUNT:-0}" -ge 1 ] || fail "no Widget custom resource found in namespace '$NS'"

echo "✓ CRD Established          : $CRD"
echo "✓ schema requires spec.size"
echo "✓ Widget resources in $NS  : $COUNT"
echo
echo "Submit this flag in the platform:"
echo
echo "    $FLAG"
