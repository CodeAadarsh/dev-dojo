#!/usr/bin/env bash
# Verifier for "Sidecar Speed Run": a Running pod in dojo-ckad with >=2
# containers sharing an emptyDir volume.
set -uo pipefail

NS=dojo-ckad
FLAG='KUBE{sidecars_share_an_emptydir}'
fail() { echo "✗ $1"; exit 1; }

kubectl get ns "$NS" >/dev/null 2>&1 || fail "namespace '$NS' missing — run setup.sh"

found=""
for p in $(kubectl -n "$NS" get pods -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  n=$(kubectl -n "$NS" get pod "$p" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null | wc -w | tr -d ' ')
  ed=$(kubectl -n "$NS" get pod "$p" -o jsonpath='{.spec.volumes[*].emptyDir}' 2>/dev/null)
  ph=$(kubectl -n "$NS" get pod "$p" -o jsonpath='{.status.phase}' 2>/dev/null)
  if [ "${n:-0}" -ge 2 ] 2>/dev/null && [ -n "$ed" ] && [ "$ph" = "Running" ]; then
    found="$p"; break
  fi
done

[ -n "$found" ] || fail "need a Running pod in $NS with >=2 containers sharing an emptyDir volume"

echo "✓ Running pod with 2+ containers + shared emptyDir: $found"
echo
echo "Submit this flag:"
echo
echo "    $FLAG"
