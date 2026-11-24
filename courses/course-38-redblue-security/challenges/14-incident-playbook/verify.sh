#!/usr/bin/env bash
set -uo pipefail

NAMESPACE="dojo-sec-incident"
FLAG="KUBE{detect_contain_recover_in_order}"

fail() { echo "FAIL: $1" >&2; exit 1; }

echo "Running PICERL checks..."
echo ""

# I — IDENTIFY: ConfigMap incident-identified with compromised_resource=processor
IDENTIFIED=$(kubectl get configmap incident-identified -n "$NAMESPACE" \
  -o jsonpath='{.data.compromised_resource}' 2>/dev/null) || \
  fail "[I] ConfigMap 'incident-identified' not found. kubectl create configmap incident-identified -n $NAMESPACE --from-literal=compromised_resource=processor"

[ "$IDENTIFIED" = "processor" ] || \
  fail "[I] incident-identified.compromised_resource is '$IDENTIFIED', expected 'processor'"
echo "[I] IDENTIFY: OK — compromised_resource=processor"

# C — CONTAIN: NetworkPolicy isolate-processor exists
kubectl get networkpolicy isolate-processor -n "$NAMESPACE" >/dev/null 2>&1 || \
  fail "[C] NetworkPolicy 'isolate-processor' not found in $NAMESPACE. Create a deny-all NetworkPolicy named isolate-processor."
echo "[C] CONTAIN: OK — NetworkPolicy isolate-processor exists"

# E — ERADICATE: Secret payment-db-creds annotated as rotated
ROTATED=$(kubectl get secret payment-db-creds -n "$NAMESPACE" \
  -o jsonpath='{.metadata.annotations.dojo\.incident/rotated}' 2>/dev/null) || \
  fail "[E] Secret 'payment-db-creds' not found in $NAMESPACE"

[ "$ROTATED" = "true" ] || \
  fail "[E] payment-db-creds annotation dojo.incident/rotated is '$ROTATED', expected 'true'. Run: kubectl annotate secret payment-db-creds dojo.incident/rotated=true -n $NAMESPACE"
echo "[E] ERADICATE: OK — payment-db-creds annotated as rotated"

# R — RECOVER: Deployment processor has been restarted (generation > 1)
GEN=$(kubectl get deployment processor -n "$NAMESPACE" \
  -o jsonpath='{.metadata.generation}' 2>/dev/null) || \
  fail "[R] Deployment 'processor' not found in $NAMESPACE"

[ "$GEN" -gt 1 ] 2>/dev/null || \
  fail "[R] Deployment 'processor' generation is $GEN — must be > 1. Run: kubectl rollout restart deployment processor -n $NAMESPACE"
echo "[R] RECOVER: OK — deployment restarted (generation=$GEN)"

# L — LESSONS: ConfigMap incident-rca exists with root_cause
kubectl get configmap incident-rca -n "$NAMESPACE" >/dev/null 2>&1 || \
  fail "[L] ConfigMap 'incident-rca' not found. kubectl create configmap incident-rca -n $NAMESPACE --from-literal=root_cause=compromised_sa_token"

ROOT_CAUSE=$(kubectl get configmap incident-rca -n "$NAMESPACE" \
  -o jsonpath='{.data.root_cause}' 2>/dev/null)

[ -n "$ROOT_CAUSE" ] || \
  fail "[L] incident-rca.root_cause is empty. Add a root_cause to the ConfigMap."
echo "[L] LESSONS: OK — root_cause recorded"

echo ""
echo "All PICERL steps verified."
echo ""
echo "FLAG: $FLAG"
