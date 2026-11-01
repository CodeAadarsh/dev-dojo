#!/usr/bin/env bash
# Verifier for "Ship the Operator".
# Checks CRD Established + controller Deployment readyReplicas >= 1.
# No jq; uses -o jsonpath throughout.
set -uo pipefail

FLAG='KUBE{operator_deployed_crds_are_alive}'

fail() { echo "✗ $1"; exit 1; }

# ── context guard ─────────────────────────────────────────────────────────────
CURRENT_CTX=$(kubectl config current-context 2>/dev/null || echo "")
if [ "$CURRENT_CTX" != "kind-dojo" ]; then
	echo "WARNING: current context is '${CURRENT_CTX}', expected 'kind-dojo'."
	echo "         Switch with: kubectl config use-context kind-dojo"
	echo "         Proceeding anyway — you may be running against an equivalent cluster."
fi

# ── check 1: CRD widgets.dojo.dev is Established ─────────────────────────────
CRD_STATUS=$(kubectl get crd widgets.dojo.dev \
	-o jsonpath='{.status.conditions[?(@.type=="Established")].status}' \
	2>/dev/null || echo "")

[ "$CRD_STATUS" = "True" ] \
	|| fail "CRD widgets.dojo.dev is not Established (got: '${CRD_STATUS}'). Apply the CRD with: kubectl apply -f config/crd/"

# ── check 2: Deployment widget-controller-manager has readyReplicas >= 1 ──────
READY=$(kubectl get deployment widget-controller-manager \
	-n dojo-operator \
	-o jsonpath='{.status.readyReplicas}' \
	2>/dev/null || echo "0")

READY="${READY:-0}"

if ! [ "$READY" -ge 1 ] 2>/dev/null; then
	echo "✗ controller Deployment has no ready replicas (readyReplicas='${READY}')"
	echo "  Diagnose:"
	echo "    kubectl -n dojo-operator get pods"
	echo "    kubectl -n dojo-operator describe deployment widget-controller-manager"
	echo "    kubectl -n dojo-operator logs -l control-plane=controller-manager"
	exit 1
fi

echo
echo "CRD widgets.dojo.dev: Established"
echo "Deployment widget-controller-manager: readyReplicas=${READY}"
echo
echo "Submit this flag in the platform:"
echo
echo "    $FLAG"
