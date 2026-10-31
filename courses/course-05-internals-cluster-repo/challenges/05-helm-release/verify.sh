#!/usr/bin/env bash
# Verifier for "Package It With Helm". Confirms a Helm release named 'web' exists
# in dojo-helm AND its workload is Ready, then prints the flag.
# Exit 0 = solved, 1 = not yet. kubectl + helm + POSIX only (no jq).
set -uo pipefail

NS=dojo-helm
REL=web
FLAG='KUBE{charts_render_values_into_releases}'

fail() { echo "✗ $1"; exit 1; }

command -v helm >/dev/null 2>&1 || fail "'helm' is not installed — this challenge requires it (brew install helm)"
kubectl get ns "$NS" >/dev/null 2>&1 || fail "namespace '$NS' is missing — run setup.sh first"

# (1) a Helm release named exactly 'web' must exist in dojo-helm
helm -n "$NS" list -q 2>/dev/null | grep -qx "$REL" \
  || fail "no Helm release named '$REL' in $NS — run: helm install $REL ./web -n $NS"

# (2) its workload (Deployment or StatefulSet, Helm instance label) must be Ready
READY=$(kubectl -n "$NS" get deploy,statefulset \
  -l app.kubernetes.io/instance="$REL" \
  -o jsonpath='{.items[*].status.readyReplicas}' 2>/dev/null)

TOTAL=0
for r in $READY; do
  [ "$r" -ge 0 ] 2>/dev/null && TOTAL=$((TOTAL + r))
done

if ! [ "$TOTAL" -ge 1 ] 2>/dev/null; then
  fail "release '$REL' has no Ready pods yet (need readyReplicas>=1; found: ${TOTAL}) — check: kubectl -n $NS get pods"
fi

REV=$(helm -n "$NS" history "$REL" 2>/dev/null | grep -c -E '^[0-9]+')

echo "✓ Helm release present     : $REL (in $NS)"
echo "✓ release revisions         : ${REV:-?}"
echo "✓ workload readyReplicas    : $TOTAL"
echo
echo "Chart installed and Ready. Submit this flag in the platform:"
echo
echo "    $FLAG"
