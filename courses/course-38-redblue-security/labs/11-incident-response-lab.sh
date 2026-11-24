#!/usr/bin/env bash
# Lab 11: CIS Hardening & Incident Response — sets up an incident scenario to triage
set -euo pipefail

NAMESPACE="dojo-sec-incident"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -n "$NAMESPACE" -f - <<'EOF'
# Backdoor SA (represents what an attacker would leave behind)
apiVersion: v1
kind: ServiceAccount
metadata:
  name: node-monitor-sa
  namespace: dojo-sec-incident
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: dojo-sec-incident-backdoor
subjects:
- kind: ServiceAccount
  name: node-monitor-sa
  namespace: dojo-sec-incident
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
---
# Suspicious pod (represents the compromised workload to triage)
apiVersion: v1
kind: Pod
metadata:
  name: suspicious-pod
  namespace: dojo-sec-incident
  labels:
    app: suspicious-pod
    incident: detected
spec:
  serviceAccountName: node-monitor-sa
  containers:
  - name: c
    image: alpine:3.20
    command:
    - sh
    - -c
    - |
      # Simulate attacker commands that Falco would have alerted on:
      echo "Simulated: id, uname -a, env, ls /var/run/secrets" >/tmp/commands-run.txt
      sleep 86400
    env:
    - name: EXFIL_TARGET
      value: "attacker.example.com"
    - name: DB_PASSWORD
      value: "stolen_db_password_123"
---
# "Normal" pod in the same namespace for comparison
apiVersion: v1
kind: Pod
metadata:
  name: legitimate-pod
  namespace: dojo-sec-incident
  labels:
    app: legitimate-pod
spec:
  containers:
  - name: app
    image: alpine:3.20
    command: [sleep, "86400"]
EOF

kubectl wait --for=condition=ready pod/suspicious-pod -n "$NAMESPACE" --timeout=90s
kubectl wait --for=condition=ready pod/legitimate-pod -n "$NAMESPACE" --timeout=90s

echo ""
echo "Incident response lab ready."
echo ""
echo "Scenario: Falco alerted on 'Shell Spawned in Container' in suspicious-pod."
echo ""
echo "Triage exercises (from Module 11 playbook):"
echo "  1. Describe the pod: kubectl describe pod suspicious-pod -n $NAMESPACE"
echo "  2. Check processes: kubectl exec -n $NAMESPACE suspicious-pod -- ps aux"
echo "  3. Check network: kubectl exec -n $NAMESPACE suspicious-pod -- cat /proc/net/tcp"
echo "  4. Check env (may contain stolen creds): kubectl exec -n $NAMESPACE suspicious-pod -- env"
echo "  5. Find the backdoor SA: kubectl get clusterrolebindings | grep incident"
echo ""
echo "Containment exercises:"
echo "  6. Isolate with NetworkPolicy (Module 11)"
echo "  7. Collect forensic artifacts before deleting"
echo "  8. Delete the pod and backdoor: kubectl delete pod suspicious-pod -n $NAMESPACE"
echo "     kubectl delete clusterrolebinding dojo-sec-incident-backdoor"
