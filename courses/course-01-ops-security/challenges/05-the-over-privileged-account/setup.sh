#!/usr/bin/env bash
# Plants "The Over-Privileged Account": a CI ServiceAccount (dojo-rbac/ci-runner)
# bound cluster-wide to a ClusterRole far broader than a CI runner needs —
# enough to read Secrets in a separate vault namespace (dojo-vault).
set -euo pipefail

NS=dojo-rbac
VAULT_NS=dojo-vault

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Targeting your current context anyway."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace "$VAULT_NS" --dry-run=client -o yaml | kubectl apply -f -

# The CI identity that got over-provisioned.
kubectl -n "$NS" create serviceaccount ci-runner \
  --dry-run=client -o yaml | kubectl apply -f -

# The production credentials another team believes RBAC is isolating.
kubectl -n "$VAULT_NS" create secret generic vault-secret \
  --from-literal=DB_ROOT_PASSWORD='s3cr3t-do-not-share' \
  --from-literal=FLAG='KUBE{over_privileged_ci_reads_the_vault}' \
  --dry-run=client -o yaml | kubectl apply -f -

# A ClusterRole far broader than a CI runner needs, bound cluster-wide.
cat <<'YAML' | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: dojo-ci-runner-toobig
  labels:
    dojo: over-privileged-account
rules:
  - apiGroups: [""]
    resources: ["secrets", "configmaps", "pods"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["deployments", "replicasets", "statefulsets", "daemonsets"]
    verbs: ["*"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: dojo-ci-runner-toobig
  labels:
    dojo: over-privileged-account
subjects:
  - kind: ServiceAccount
    name: ci-runner
    namespace: dojo-rbac
roleRef:
  kind: ClusterRole
  name: dojo-ci-runner-toobig
  apiGroup: rbac.authorization.k8s.io
YAML

echo
echo "✓ Scenario deployed."
echo "  Namespace '$NS'   : ServiceAccount 'ci-runner'."
echo "  Namespace '$VAULT_NS' : Secret 'vault-secret' holding the flag."
echo "  RBAC              : ClusterRole 'dojo-ci-runner-toobig' bound to ci-runner"
echo "                      via a ClusterRoleBinding (cluster-wide blast radius)."
echo
echo "Next: discover ci-runner's real reach, then read the flag AS that identity."
echo "  kubectl auth can-i --list --as=system:serviceaccount:dojo-rbac:ci-runner"
