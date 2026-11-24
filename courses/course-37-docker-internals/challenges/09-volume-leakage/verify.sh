#!/usr/bin/env bash
set -uo pipefail

NAMESPACE="dojo-docker-volume"

fail() {
  echo "FAIL: $1"
  exit 1
}

echo "==> Verifying: Volume Leakage"

# Check 1: Deployment has at least one volume defined
VOLUMES=$(kubectl get deployment counter -n "$NAMESPACE" \
  -o jsonpath='{.spec.template.spec.volumes}' 2>/dev/null || echo "")
if [ -z "$VOLUMES" ] || [ "$VOLUMES" = "[]" ] || [ "$VOLUMES" = "null" ]; then
  fail "Deployment 'counter' has no volumes defined. Add a volume (emptyDir is fine) under spec.template.spec.volumes."
fi
echo "    [OK] Deployment has volumes defined"

# Check 2: Container has a volumeMount at /data
MOUNT_PATH=$(kubectl get deployment counter -n "$NAMESPACE" \
  -o jsonpath='{.spec.template.spec.containers[0].volumeMounts[0].mountPath}' 2>/dev/null || echo "")
if [ "$MOUNT_PATH" != "/data" ]; then
  fail "Container's first volumeMount is not at /data (got: '${MOUNT_PATH}'). Mount your volume at /data."
fi
echo "    [OK] Volume mounted at /data"

# Check 3: At least one pod is Running
RUNNING=$(kubectl get pods -n "$NAMESPACE" -l app=counter \
  -o jsonpath='{.items[*].status.phase}' 2>/dev/null || echo "")
if ! echo "$RUNNING" | grep -qw "Running"; then
  fail "No Running pod found for Deployment 'counter'. Check 'kubectl get pods -n $NAMESPACE'."
fi
echo "    [OK] Pod is Running"

echo ""
echo "    Flag: KUBE{volume_persists_across_restart}"
