#!/usr/bin/env bash
# Plants the "Shut the Flat Network" scenario: a backend service reachable by
# every pod in the namespace (a flat network), plus an authorized frontend and
# an unauthorized attacker client. The learner adds default-deny + scoped-allow
# NetworkPolicies. Idempotent.
set -euo pipefail

NS=dojo-hardnet

if ! kubectl config current-context 2>/dev/null | grep -q kind-dojo; then
  echo "⚠  Current kube-context is not 'kind-dojo'. Targeting your current context anyway."
  echo "   (Run: kubectl config use-context kind-dojo)"
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

cat <<'YAML' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: backend
  namespace: dojo-hardnet
  labels:
    app: backend
spec:
  containers:
    - name: backend
      image: nginx:1.27-alpine
      ports:
        - containerPort: 80
---
apiVersion: v1
kind: Pod
metadata:
  name: frontend
  namespace: dojo-hardnet
  labels:
    app: client
    role: frontend
spec:
  containers:
    - name: client
      image: busybox:1.36
      command: ["sh", "-c", "sleep 3600"]
---
apiVersion: v1
kind: Pod
metadata:
  name: attacker
  namespace: dojo-hardnet
  labels:
    app: client
    role: other
spec:
  containers:
    - name: client
      image: busybox:1.36
      command: ["sh", "-c", "sleep 3600"]
YAML

kubectl -n "$NS" wait --for=condition=Ready pod/backend --timeout=60s >/dev/null 2>&1 || true

echo
echo "✓ Scenario deployed to namespace '$NS'."
echo "  Planted (flat network — every pod can reach backend:80):"
echo "    - Pod 'backend'  (nginx:1.27-alpine, :80, labels app=backend)"
echo "    - Pod 'frontend' (busybox:1.36, labels app=client,role=frontend)  <- allowed"
echo "    - Pod 'attacker' (busybox:1.36, labels app=client,role=other)     <- must be denied"
echo
echo "  Next: apply a default-deny-ingress NetworkPolicy AND a scoped allow"
echo "  policy (role=frontend -> app=backend:80), then run verify.sh."
echo "  NOTE: kindnet does not enforce policy — the verifier checks the policy"
echo "        objects, not live packet drops. See brief.md."
