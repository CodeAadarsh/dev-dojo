#!/usr/bin/env bash
set -uo pipefail

NAMESPACE="dojo-sec-gauntlet"
PASS_COUNT=0
fail() { echo "FAIL: $*"; exit 1; }
pass() { echo "    [PASS] $*"; PASS_COUNT=$((PASS_COUNT + 1)); }

echo "==> Verifying: Admission Gauntlet"
kubectl get namespace "$NAMESPACE" > /dev/null 2>&1 || fail "Namespace $NAMESPACE not found — run setup.sh first"

try_create_and_expect_denied() {
  local name="$1"
  local desc="$2"
  shift 2
  local result
  result=$(kubectl apply -f - 2>&1 "$@" <<PODEOF
$STDIN_MANIFEST
PODEOF
  ) || true

  # Clean up if somehow created
  kubectl delete pod "$name" -n "$NAMESPACE" --ignore-not-found=true > /dev/null 2>&1

  if echo "$result" | grep -qiE "(denied|forbidden|violat|not allowed|must not|cannot)"; then
    pass "$desc"
  else
    echo "    [FAIL] $desc"
    echo "           Pod '$name' was NOT rejected (result: $result)"
    echo "           Apply a policy to block this before running verify.sh again"
  fi
}

# Attack 1: Privileged container
echo "    Testing attack 1: privileged container..."
RESULT1=$(kubectl apply -f - 2>&1 <<'EOF' || true
apiVersion: v1
kind: Pod
metadata:
  name: attack-priv
  namespace: dojo-sec-gauntlet
spec:
  containers:
  - name: c
    image: busybox:1.36
    securityContext:
      privileged: true
    command: [sleep, "1"]
EOF
)
kubectl delete pod attack-priv -n "$NAMESPACE" --ignore-not-found=true > /dev/null 2>&1
if echo "$RESULT1" | grep -qiE "(denied|forbidden|violat|not allowed|must not|cannot)"; then
  pass "Attack 1 (privileged) blocked"
else
  echo "    [FAIL] Attack 1 (privileged) NOT blocked — apply OPA BlockPrivileged constraint"
fi

# Attack 2: hostPath root
echo "    Testing attack 2: hostPath: / ..."
RESULT2=$(kubectl apply -f - 2>&1 <<'EOF' || true
apiVersion: v1
kind: Pod
metadata:
  name: attack-hostpath
  namespace: dojo-sec-gauntlet
spec:
  containers:
  - name: c
    image: busybox:1.36
    command: [sleep, "1"]
    volumeMounts:
    - name: host
      mountPath: /host
  volumes:
  - name: host
    hostPath:
      path: /
EOF
)
kubectl delete pod attack-hostpath -n "$NAMESPACE" --ignore-not-found=true > /dev/null 2>&1
if echo "$RESULT2" | grep -qiE "(denied|forbidden|violat|not allowed|must not|cannot)"; then
  pass "Attack 2 (hostPath root) blocked"
else
  echo "    [FAIL] Attack 2 (hostPath root) NOT blocked — apply OPA BlockHostPathRoot constraint"
fi

# Attack 3: No resource limits
echo "    Testing attack 3: no resource limits..."
RESULT3=$(kubectl apply -f - 2>&1 <<'EOF' || true
apiVersion: v1
kind: Pod
metadata:
  name: attack-nolimits
  namespace: dojo-sec-gauntlet
spec:
  containers:
  - name: c
    image: busybox:1.36
    command: [sleep, "1"]
EOF
)
kubectl delete pod attack-nolimits -n "$NAMESPACE" --ignore-not-found=true > /dev/null 2>&1
if echo "$RESULT3" | grep -qiE "(denied|forbidden|violat|not allowed|must not|cannot)"; then
  pass "Attack 3 (no resource limits) blocked"
else
  echo "    [FAIL] Attack 3 (no resource limits) NOT blocked — apply Kyverno require-limits policy"
fi

# Attack 4: Untagged image (image: nginx — no :tag)
echo "    Testing attack 4: untagged image..."
RESULT4=$(kubectl apply -f - 2>&1 <<'EOF' || true
apiVersion: v1
kind: Pod
metadata:
  name: attack-notag
  namespace: dojo-sec-gauntlet
spec:
  containers:
  - name: c
    image: nginx
    resources:
      limits:
        cpu: "100m"
        memory: "64Mi"
EOF
)
kubectl delete pod attack-notag -n "$NAMESPACE" --ignore-not-found=true > /dev/null 2>&1
if echo "$RESULT4" | grep -qiE "(denied|forbidden|violat|not allowed|must not|cannot|latest)"; then
  pass "Attack 4 (untagged image) blocked"
else
  echo "    [FAIL] Attack 4 (untagged image) NOT blocked — apply Kyverno no-untagged-images policy"
fi

# Attack 5: Banned service account
echo "    Testing attack 5: banned SA..."
RESULT5=$(kubectl apply -f - 2>&1 <<'EOF' || true
apiVersion: v1
kind: Pod
metadata:
  name: attack-badsa
  namespace: dojo-sec-gauntlet
spec:
  serviceAccountName: dojo-sec-gauntlet-admin
  containers:
  - name: c
    image: busybox:1.36
    resources:
      limits:
        cpu: "100m"
        memory: "64Mi"
    command: [sleep, "1"]
EOF
)
kubectl delete pod attack-badsa -n "$NAMESPACE" --ignore-not-found=true > /dev/null 2>&1
if echo "$RESULT5" | grep -qiE "(denied|forbidden|violat|not allowed|must not|cannot)"; then
  pass "Attack 5 (banned SA) blocked"
else
  echo "    [FAIL] Attack 5 (banned SA) NOT blocked — apply Kyverno block-admin-sa policy"
fi

echo ""
echo "    Score: $PASS_COUNT/5"

if [ "$PASS_COUNT" -lt 5 ]; then
  fail "Not all 5 attacks are blocked yet. Apply the missing policies and re-run."
fi

# Read the flag
FLAG_B64=$(kubectl get secret gauntlet-reward -n "$NAMESPACE" -o jsonpath='{.data.flag}' 2>/dev/null)
[ -n "$FLAG_B64" ] || fail "Reward secret not found — run setup.sh first"
FLAG=$(printf '%s' "$FLAG_B64" | base64 -d)

echo ""
echo "==> All 5 attack patterns blocked by admission policies."
echo ""
echo "$FLAG"
