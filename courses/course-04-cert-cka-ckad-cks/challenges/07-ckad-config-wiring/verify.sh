#!/usr/bin/env bash
# Verifier for "Wire It Up": Deployment 'app' in dojo-wire uses envFrom a
# ConfigMap AND mounts a Secret as a volume, and is Ready.
set -uo pipefail

NS=dojo-wire
D=app
FLAG='KUBE{configmap_env_secret_volume_wired}'
fail() { echo "✗ $1"; exit 1; }

kubectl -n "$NS" get deploy "$D" >/dev/null 2>&1 || fail "deployment '$D' not found in $NS"
jp() { kubectl -n "$NS" get deploy "$D" -o jsonpath="$1" 2>/dev/null; }

EF="$(jp '{.spec.template.spec.containers[0].envFrom[*].configMapRef.name}')"
[ -n "$EF" ] || fail "container must consume a ConfigMap via envFrom (configMapRef)"

SV="$(jp '{.spec.template.spec.volumes[*].secret.secretName}')"
[ -n "$SV" ] || fail "a pod volume must reference a Secret (volumes[].secret.secretName)"

VM="$(jp '{.spec.template.spec.containers[0].volumeMounts[*].name}')"
[ -n "$VM" ] || fail "the Secret volume must be mounted into the container (volumeMounts)"

READY="$(jp '{.status.readyReplicas}')"
[ "${READY:-0}" -ge 1 ] 2>/dev/null || fail "'$D' has no Ready replica (missing ConfigMap/Secret?). readyReplicas=${READY:-0}"

echo "✓ envFrom ConfigMap   : $EF"
echo "✓ Secret volume       : $SV  (mount: $VM)"
echo "✓ readyReplicas       : $READY"
echo
echo "Submit this flag:"
echo
echo "    $FLAG"
