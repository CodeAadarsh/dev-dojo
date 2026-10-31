#!/usr/bin/env bash
# Plants the "Bind Thyself Admin" scenario: a ServiceAccount 'dev' that CANNOT
# read Secrets directly, but CAN create RoleBindings and holds the `bind` verb
# on a secret-reading Role — the RBAC self-escalation primitive from Module 01's
# "pod creates a privileged binding" link.
set -euo pipefail

NS=dojo-esc

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Targeting your current context anyway."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

# The crown-jewel Secret 'dev' must NOT be able to read at the start.
kubectl -n "$NS" create secret generic crown-jewels \
  --from-literal=DB_PASSWORD=decoy-not-the-flag \
  --from-literal=FLAG='KUBE{bind_verb_is_privilege_escalation}' \
  --dry-run=client -o yaml | kubectl apply -f -

# dev + the Role it WANTS (secret-reader, NOT bound to it) + the Role it HAS
# (binder: create rolebindings + `bind` on secret-reader) + that binding.
cat <<'YAML' | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: dev
  namespace: dojo-esc
---
# The target Role. 'dev' is deliberately NOT bound to this at setup time.
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: secret-reader
  namespace: dojo-esc
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list"]
---
# What 'dev' IS granted: create RoleBindings, and the `bind` verb on the
# secret-reader Role. Note there is NO direct secret access anywhere here.
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: binder
  namespace: dojo-esc
rules:
  - apiGroups: ["rbac.authorization.k8s.io"]
    resources: ["rolebindings"]
    verbs: ["create", "get", "list"]
  - apiGroups: ["rbac.authorization.k8s.io"]
    resources: ["roles"]
    verbs: ["bind"]
    resourceNames: ["secret-reader"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: dev-is-a-binder
  namespace: dojo-esc
subjects:
  - kind: ServiceAccount
    name: dev
    namespace: dojo-esc
roleRef:
  kind: Role
  name: binder
  apiGroup: rbac.authorization.k8s.io
YAML

echo
echo "✓ Scenario deployed to namespace '$NS'."
echo "  Planted:"
echo "    - Secret 'crown-jewels' (holds FLAG=KUBE{...} plus a decoy DB_PASSWORD)"
echo "    - ServiceAccount 'dev' — CANNOT read secrets directly"
echo "    - Role 'binder' bound to 'dev': create rolebindings + 'bind' on Role 'secret-reader'"
echo "    - Role 'secret-reader' (get/list secrets) exists but is NOT bound to 'dev'"
echo
echo "  Confirm the starting point (should print 'no'):"
echo "    kubectl auth can-i get secrets -n $NS --as=system:serviceaccount:$NS:dev"
echo
echo "  Mission: AS 'dev', self-grant secret-reader via a RoleBinding, then read the flag."
