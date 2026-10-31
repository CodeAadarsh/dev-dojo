#!/usr/bin/env bash
# Verifier for "Mimir Remote-Write with Multi-Tenant OrgID".
# Checks: Helm release for mimir present, a mimir Deployment/StatefulSet exists,
# and a ConfigMap named prometheus-remote-write-config contains the mimir
# endpoint URL AND an X-Scope-OrgID (or equivalent) reference.
set -uo pipefail

NS=dojo-lgtm
FLAG='KUBE{mimir_remote_write_multitenant}'

fail() { echo "✗ $1"; exit 1; }

# 1. Namespace must exist
kubectl get ns "$NS" >/dev/null 2>&1 || fail "namespace '$NS' is missing — run setup.sh first"

# 2. A Helm release whose name contains 'mimir' must exist
RELEASE=$(helm -n "$NS" list -q 2>/dev/null | grep mimir || true)
[ -n "$RELEASE" ] || fail "no Helm release matching 'mimir' found in $NS — install with: helm install mimir grafana/mimir-distributed -n $NS -f values.yaml"

# 3. A Deployment or StatefulSet whose name contains 'mimir' must exist
WORKLOAD=$(kubectl -n "$NS" get deploy,statefulset -o name 2>/dev/null | grep mimir | head -1 || true)
[ -n "$WORKLOAD" ] || fail "no Deployment/StatefulSet matching 'mimir' found in $NS — check: kubectl -n $NS get deploy,statefulset"

# 4. ConfigMap 'prometheus-remote-write-config' must exist
kubectl -n "$NS" get cm prometheus-remote-write-config >/dev/null 2>&1 \
  || fail "ConfigMap 'prometheus-remote-write-config' not found in $NS — create it with the remote_write config"

# 5. The ConfigMap must contain a Mimir push endpoint reference
CM_DATA=$(kubectl -n "$NS" get cm prometheus-remote-write-config -o jsonpath='{.data}' 2>/dev/null || true)
echo "$CM_DATA" | grep -q "api/v1/push" \
  || fail "ConfigMap 'prometheus-remote-write-config' must reference a Mimir push endpoint (/api/v1/push)"

# 6. The ConfigMap must reference X-Scope-OrgID (case-insensitive match on orgid/org_id)
echo "$CM_DATA" | grep -qi "X-Scope-OrgID\|orgid\|org_id" \
  || fail "ConfigMap 'prometheus-remote-write-config' must include X-Scope-OrgID (or orgid/org_id) for multi-tenant routing"

echo "✓ Helm release   : $RELEASE"
echo "✓ Mimir workload : $WORKLOAD"
echo "✓ ConfigMap      : prometheus-remote-write-config (endpoint + OrgID present)"
echo
echo "All checks passed. Submit this flag in the platform:"
echo
echo "    $FLAG"
