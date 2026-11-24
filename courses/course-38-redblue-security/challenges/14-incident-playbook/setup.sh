#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="dojo-sec-incident"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: processor-sa
  namespace: $NAMESPACE
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: secret-lister
  namespace: $NAMESPACE
rules:
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: processor-secret-access
  namespace: $NAMESPACE
subjects:
- kind: ServiceAccount
  name: processor-sa
  namespace: $NAMESPACE
roleRef:
  kind: Role
  name: secret-lister
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: v1
kind: Secret
metadata:
  name: payment-db-creds
  namespace: $NAMESPACE
type: Opaque
stringData:
  password: "prod-payment-db-hunter2"
  host: "payments-db.internal:5432"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: processor
  namespace: $NAMESPACE
  labels:
    app: processor
spec:
  replicas: 1
  selector:
    matchLabels:
      app: processor
  template:
    metadata:
      labels:
        app: processor
    spec:
      serviceAccountName: processor-sa
      containers:
      - name: processor
        image: alpine:3.20
        command: ["sh", "-c", "echo 'attacker backdoor installed' > /tmp/attacker-backdoor; sleep 86400"]
        env:
        - name: DB_PASSWORD
          valueFrom:
            secretKeyRef:
              name: payment-db-creds
              key: password
        resources:
          limits:
            cpu: "100m"
            memory: "64Mi"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: falco-alert
  namespace: $NAMESPACE
data:
  alert: |
    {
      "time": "2024-01-15T02:34:00.000000000Z",
      "rule": "Terminal shell in container",
      "priority": "NOTICE",
      "output": "A shell was spawned in a container with an attached terminal",
      "output_fields": {
        "container.id": "a8f3b2c1d4e5",
        "container.name": "processor",
        "k8s.ns.name": "dojo-sec-incident",
        "k8s.pod.name": "processor-7d9b4c6f8-xkm2p",
        "proc.cmdline": "sh -i",
        "user.name": "root"
      }
    }
  note: "This is the Falco alert that triggered your pager. The attacker spawned an interactive shell and used the SA token to list secrets."
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: audit-trail
  namespace: $NAMESPACE
data:
  audit_entries: |
    {"timestamp":"2024-01-15T02:33:41Z","verb":"list","resource":"secrets","namespace":"dojo-sec-incident","user":"system:serviceaccount:dojo-sec-incident:processor-sa","responseStatus":{"code":200}}
    {"timestamp":"2024-01-15T02:33:42Z","verb":"get","resource":"secrets","name":"payment-db-creds","namespace":"dojo-sec-incident","user":"system:serviceaccount:dojo-sec-incident:processor-sa","responseStatus":{"code":200}}
  note: "The SA token was used to read payment-db-creds. Rotate immediately."
EOF

echo ""
echo "Setup complete. Namespace: $NAMESPACE"
echo ""
echo "Simulated incident:"
echo "  - Falco alert: shell spawned in processor pod"
echo "  - Audit log: processor-sa listed and read secrets"
echo "  - Backdoor file: /tmp/attacker-backdoor in the processor pod"
echo ""
echo "Follow PICERL. Run verify.sh when done."
