#!/usr/bin/env bash
# Plants the "Stolen ServiceAccount Token" scenario: a pod running as a
# ServiceAccount whose Role can read Secrets, with its token automounted — the
# pod-to-cluster escalation link from Module 01.
set -euo pipefail

NS=dojo-ctf

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Targeting your current context anyway."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

# The Secret the worker should never have been able to read.
kubectl -n "$NS" create secret generic db-credentials \
  --from-literal=DB_HOST=postgres.dojo-ctf.svc \
  --from-literal=DB_USER=app \
  --from-literal=DB_PASSWORD=sup3r-s3cret-not-really \
  --from-literal=FLAG='KUBE{mounted_token_reads_the_secret}' \
  --dry-run=client -o yaml | kubectl apply -f -

# ServiceAccount + Role (get/list secrets) + RoleBinding + the worker pod that
# runs as that SA with its token automounted.
cat <<'YAML' | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: worker-sa
  namespace: dojo-ctf
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: secret-reader
  namespace: dojo-ctf
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: worker-can-read-secrets
  namespace: dojo-ctf
subjects:
  - kind: ServiceAccount
    name: worker-sa
    namespace: dojo-ctf
roleRef:
  kind: Role
  name: secret-reader
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: v1
kind: Pod
metadata:
  name: worker
  namespace: dojo-ctf
  labels:
    app: worker
spec:
  serviceAccountName: worker-sa
  automountServiceAccountToken: true
  containers:
    - name: worker
      image: busybox:1.36
      command: ["sh", "-c", "sleep 3600"]
YAML

kubectl -n "$NS" wait --for=condition=Ready pod/worker --timeout=60s >/dev/null 2>&1 || true

echo
echo "✓ Scenario deployed to namespace '$NS'."
echo "  Planted:"
echo "    - Secret 'db-credentials' (holds FLAG=KUBE{...} plus decoy keys)"
echo "    - ServiceAccount 'worker-sa' + Role 'secret-reader' (get/list secrets)"
echo "    - Pod 'worker' (busybox:1.36) running AS worker-sa, token automounted"
echo
echo "  Next: get a shell in the pod and use its MOUNTED token to hit the API —"
echo "    kubectl -n $NS exec -it worker -- sh"
echo "  then read the token/ca.crt/namespace under"
echo "    /var/run/secrets/kubernetes.io/serviceaccount/"
echo "  and curl https://kubernetes.default.svc to read the Secret. Submit the flag."
