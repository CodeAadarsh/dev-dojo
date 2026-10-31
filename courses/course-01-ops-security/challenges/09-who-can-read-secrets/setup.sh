#!/usr/bin/env bash
# Plants "Who Can Read Secrets?": three ServiceAccounts in dojo-secrets, each
# with a narrow Role scoped (via resourceNames) to exactly one of three Secrets.
# Only one SA can get the Secret holding the flag.
set -euo pipefail

NS=dojo-secrets

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Targeting your current context anyway."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

# Three ServiceAccounts.
for sa in app-a app-b app-c; do
  kubectl -n "$NS" create serviceaccount "$sa" --dry-run=client -o yaml | kubectl apply -f -
done

# Three Secrets. Only payments-api-key holds the flag; the others are decoys.
kubectl -n "$NS" create secret generic payments-api-key \
  --from-literal=API_KEY='pk_live_do_not_log_me' \
  --from-literal=FLAG='KUBE{enumerate_rbac_to_find_the_reader}' \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$NS" create secret generic telemetry-token \
  --from-literal=TOKEN='tkn_metrics_push_0001' \
  --from-literal=NOTE='decoy - not the flag, keep enumerating' \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$NS" create secret generic frontend-config \
  --from-literal=THEME='dark' \
  --from-literal=NOTE='decoy - not the flag, keep enumerating' \
  --dry-run=client -o yaml | kubectl apply -f -

# Three narrow Roles, each scoped to exactly one Secret by resourceNames.
# app-a -> telemetry-token, app-b -> payments-api-key, app-c -> frontend-config.
cat <<'YAML' | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: read-telemetry-token
  namespace: dojo-secrets
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: ["telemetry-token"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: read-payments-api-key
  namespace: dojo-secrets
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: ["payments-api-key"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: read-frontend-config
  namespace: dojo-secrets
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: ["frontend-config"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: app-a-read-telemetry
  namespace: dojo-secrets
subjects:
  - kind: ServiceAccount
    name: app-a
    namespace: dojo-secrets
roleRef:
  kind: Role
  name: read-telemetry-token
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: app-b-read-payments
  namespace: dojo-secrets
subjects:
  - kind: ServiceAccount
    name: app-b
    namespace: dojo-secrets
roleRef:
  kind: Role
  name: read-payments-api-key
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: app-c-read-frontend
  namespace: dojo-secrets
subjects:
  - kind: ServiceAccount
    name: app-c
    namespace: dojo-secrets
roleRef:
  kind: Role
  name: read-frontend-config
  apiGroup: rbac.authorization.k8s.io
YAML

echo
echo "✓ Scenario deployed to namespace '$NS'."
echo "  ServiceAccounts : app-a, app-b, app-c"
echo "  Secrets         : payments-api-key (flag), telemetry-token, frontend-config"
echo "  Roles           : each SA is scoped by resourceNames to exactly one Secret."
echo
echo "Next: find which SA can 'get' the flag Secret, then read it as that identity."
echo "  for sa in app-a app-b app-c; do"
echo "    echo -n \"\$sa: \"; kubectl -n $NS auth can-i get secret/payments-api-key \\"
echo "      --as=system:serviceaccount:$NS:\$sa; done"
