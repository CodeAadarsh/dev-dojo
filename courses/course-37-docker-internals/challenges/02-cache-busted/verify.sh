#!/usr/bin/env bash
set -uo pipefail

NAMESPACE="dojo-docker-cache"
FLAG="KUBE{cache_busted_by_volatile_copy}"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

echo "==> Verifying 02-cache-busted..."

# Check fixed-dockerfile ConfigMap exists
kubectl get configmap fixed-dockerfile -n "$NAMESPACE" > /dev/null 2>&1 \
  || fail "ConfigMap 'fixed-dockerfile' not found in namespace $NAMESPACE — create it with your corrected Dockerfile"

# Extract the Dockerfile content
CONTENT=$(kubectl get configmap fixed-dockerfile -n "$NAMESPACE" -o jsonpath='{.data.Dockerfile}')
[ -n "$CONTENT" ] || fail "ConfigMap 'fixed-dockerfile' exists but the 'Dockerfile' key is empty"

# Find line numbers of COPY package and RUN npm
COPY_LINE=$(echo "$CONTENT" | grep -n "COPY package" | head -1 | cut -d: -f1 || true)
NPM_LINE=$(echo "$CONTENT"  | grep -n "RUN npm"      | head -1 | cut -d: -f1 || true)

[ -n "$COPY_LINE" ] || fail "Dockerfile must contain 'COPY package' (copying package.json before install)"
[ -n "$NPM_LINE"  ] || fail "Dockerfile must contain 'RUN npm' (the install step)"

[ "$COPY_LINE" -lt "$NPM_LINE" ] \
  || fail "Layer order still wrong: 'COPY package' (line $COPY_LINE) must come BEFORE 'RUN npm' (line $NPM_LINE)"

echo "✓ Layer order correct: COPY package (line $COPY_LINE) is before RUN npm (line $NPM_LINE)"
echo ""
echo "Flag: $FLAG"
