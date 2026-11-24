#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="dojo-sec-evasion"

echo "==> Setting up: Runtime Evasion"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Plant the flag directly in a ConfigMap (no container exec needed)
kubectl apply -f - << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: evasion-reward
  namespace: dojo-sec-evasion
  annotations:
    dojo.challenge/note: "Flag is directly readable via kubectl API — no exec needed"
data:
  flag: "KUBE{falco_rules_have_blind_spots}"
  teaching_point: |
    You retrieved this flag without execing into any container.
    Falco never fired — because Falco monitors syscalls INSIDE containers.
    kubectl API calls go to the API server over HTTPS.
    No container syscalls = no Falco alert.

    In a real incident, this means:
    - An attacker who steals a kubeconfig and reads secrets from their laptop
      triggers ZERO Falco alerts.
    - Only the Kubernetes audit log records this activity.
    - Falco + audit log together = complete coverage.
  evasion_techniques: |
    Other Falco-evasion techniques attackers use:
    1. kubectl cp instead of kubectl exec (copies files without shell spawn)
    2. Create a Job that does the work (runs briefly, Falco may fire once, job is gone)
    3. Use HTTPS API directly (curl https://k8s-api/api/v1/namespaces/prod/secrets)
    4. Memory-only operations (no disk writes, no file open syscalls)
    5. Living off the land (use pre-installed tools to avoid package installation alert)
EOF

# Deploy a "protected" pod to simulate the scenario
kubectl apply -f - << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: monitored-workload
  namespace: dojo-sec-evasion
  labels:
    app: monitored
    dojo.challenge/note: "Falco is watching this pod. Don't exec into it."
spec:
  containers:
  - name: app
    image: nginx
    ports:
    - containerPort: 80
EOF

kubectl apply -f - << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: falco-simulation
  namespace: dojo-sec-evasion
data:
  note: |
    Falco DaemonSet is simulated as watching this namespace.
    If you exec into 'monitored-workload', a Falco alert would fire:
      rule: Terminal shell in container
      container: monitored-workload
      user: root
      proc: sh
    Your goal: get the flag WITHOUT triggering this rule.
    Solution: read evasion-reward ConfigMap directly (no exec needed).
EOF

echo ""
echo "==> Setup complete."
echo ""
echo "    Read the flag WITHOUT exec: kubectl get configmap evasion-reward -n $NAMESPACE -o jsonpath='{.data.flag}'"
echo "    (No verify.sh — this is a discovery challenge)"
