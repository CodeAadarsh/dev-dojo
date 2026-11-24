#!/usr/bin/env bash
# verify.sh — Red Team Lab Boss
set -uo pipefail

NAMESPACE="dojo-sec-boss"
EXPECTED_HASH="$(cat "$(dirname "$0")/flag.sha256")"

fail() { echo "FAIL: $1" >&2; exit 1; }
pass_check() { echo "  [PASS] $1"; }

echo "=== Red Team Lab Boss Verifier ==="
echo ""
echo "Checking Attack Phase (5 attack tokens)..."
echo ""

# Attack token 1 — IMDS
T1=$(kubectl get configmap attack-token-1 -n "$NAMESPACE" \
  -o jsonpath='{.data.token}' 2>/dev/null || true)
[ -n "$T1" ] || fail "attack-token-1 not found — exec into attack-pod and curl http://fake-imds-svc/latest/meta-data/iam/security-credentials/node-role, extract SecretAccessKey, write to ConfigMap attack-token-1"
pass_check "Attack 1: IMDS token collected"

# Attack token 2 — SA token abuse
T2=$(kubectl get configmap attack-token-2 -n "$NAMESPACE" \
  -o jsonpath='{.data.token}' 2>/dev/null || true)
[ -n "$T2" ] || fail "attack-token-2 not found — read the SA token: cat /var/run/secrets/kubernetes.io/serviceaccount/token (first 20 chars), write to ConfigMap attack-token-2"
pass_check "Attack 2: ServiceAccount token collected"

# Attack token 3 — Secret enumeration
T3=$(kubectl get configmap attack-token-3 -n "$NAMESPACE" \
  -o jsonpath='{.data.token}' 2>/dev/null || true)
[ -n "$T3" ] || fail "attack-token-3 not found — decode db-creds: kubectl get secret db-creds -n dojo-sec-boss -o jsonpath='{.data.flag}' | base64 -d, write to ConfigMap attack-token-3"
pass_check "Attack 3: Secret enumeration token collected"

# Attack token 4 — Privileged pod
T4=$(kubectl get configmap attack-token-4 -n "$NAMESPACE" \
  -o jsonpath='{.data.token}' 2>/dev/null || true)
[ -n "$T4" ] || fail "attack-token-4 not found — attempt to run a privileged pod and write token-4-privileged-pod-escape to ConfigMap attack-token-4"
pass_check "Attack 4: Privileged pod token collected"

# Attack token 5 — Lateral movement
T5=$(kubectl get configmap attack-token-5 -n "$NAMESPACE" \
  -o jsonpath='{.data.token}' 2>/dev/null || true)
[ -n "$T5" ] || fail "attack-token-5 not found — list cluster configmaps: kubectl get cm -A, count kube-system ones, write to ConfigMap attack-token-5"
pass_check "Attack 5: Lateral movement token collected"

echo ""
echo "Checking Blue Team Phase (5 hardenings)..."
echo ""

# Hardening 1 — Overprivileged binding removed
kubectl get clusterrolebinding boss-overprivileged-binding >/dev/null 2>&1 \
  && fail "Hardening 1 FAIL: boss-overprivileged-binding still exists — kubectl delete clusterrolebinding boss-overprivileged-binding"
pass_check "Hardening 1: Overprivileged ClusterRoleBinding removed"

# Hardening 2 — NetworkPolicy blocking IMDS exists
NP=$(kubectl get networkpolicy -n "$NAMESPACE" \
  -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
echo "$NP" | grep -q "." \
  || fail "Hardening 2 FAIL: no NetworkPolicy found in $NAMESPACE — create a policy blocking egress to 169.254.169.254/32"
pass_check "Hardening 2: NetworkPolicy deployed"

# Hardening 3 — DB_PASSWORD not in env (pod must be recreated without it)
HAS_ENV=$(kubectl get pod attack-pod -n "$NAMESPACE" \
  -o jsonpath='{.spec.containers[0].env[?(@.name=="DB_PASSWORD")].value}' 2>/dev/null || true)
[ -z "$HAS_ENV" ] \
  || fail "Hardening 3 FAIL: DB_PASSWORD still in attack-pod env — delete and recreate attack-pod without DB_PASSWORD env var"
pass_check "Hardening 3: DB_PASSWORD removed from pod env"

# Hardening 4 — PSS label on namespace
PSS=$(kubectl get namespace "$NAMESPACE" \
  -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>/dev/null || true)
[ -n "$PSS" ] \
  || fail "Hardening 4 FAIL: Pod Security Standard not set — kubectl label namespace $NAMESPACE pod-security.kubernetes.io/enforce=restricted"
pass_check "Hardening 4: Pod Security Standard label set (enforce=$PSS)"

# Hardening 5 — Falco alert configmap exists
kubectl get configmap falco-active -n "$NAMESPACE" >/dev/null 2>&1 \
  || fail "Hardening 5 FAIL: falco-active configmap not found — kubectl create configmap falco-active -n $NAMESPACE --from-literal=status=enabled"
pass_check "Hardening 5: Falco active configmap present"

echo ""
echo "=== ALL CHECKS PASSED ==="
echo ""

FLAG="KUBE{boss_full_kill_chain_attack_and_defend}"
ACTUAL_HASH=$(printf '%s' "$FLAG" | shasum -a 256 | awk '{print $1}')

[ "$ACTUAL_HASH" = "$EXPECTED_HASH" ] || fail "internal hash mismatch — contact course maintainer"

echo "FLAG: $FLAG"
