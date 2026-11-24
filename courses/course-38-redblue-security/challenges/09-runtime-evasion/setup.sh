#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="dojo-sec-evasion"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Secret containing the flag — mounted as a volume (not env var) so the learner must exec into the pod
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: evasion-flag
  namespace: $NAMESPACE
type: Opaque
stringData:
  flag: "KUBE{falco_rules_have_blind_spots}"
EOF

# Hints ConfigMap explaining Falco blind spots
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: evasion-hints
  namespace: $NAMESPACE
data:
  hint1: "Falco's shell detection rule looks for proc.name in (sh, bash, zsh, dash, ksh, tcsh, csh). What about python3?"
  hint2: "proc.name != python3 is not in the default ruleset. Python can read files and execute commands without spawning a named shell."
  hint3: "Try: kubectl exec -n dojo-sec-evasion red-team-pod -- python3 -c \"open('/secret/flag').read()\""
  hint4: "Defense: tune Falco to also alert on python3/perl/awk executing system calls. Use eBPF-based detection that fires on execve() regardless of proc.name."
  blind_spots: "Default Falco rules are name-based. Attackers can use: python3, perl, ruby, node, awk, find -exec, xargs — anything that runs code without being named sh/bash."
EOF

# Pod that mounts the flag secret — runs python3, NOT sh/bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: red-team-pod
  namespace: $NAMESPACE
  labels:
    app: red-team
    dojo.challenge: "09-runtime-evasion"
spec:
  containers:
  - name: target
    image: python:3.12-slim
    command: ["python3", "-c", "import time; time.sleep(86400)"]
    securityContext:
      allowPrivilegeEscalation: false
      runAsNonRoot: true
      runAsUser: 1000
      readOnlyRootFilesystem: false
    volumeMounts:
    - name: flag-vol
      mountPath: /secret
      readOnly: true
    resources:
      limits:
        cpu: "200m"
        memory: "128Mi"
  volumes:
  - name: flag-vol
    secret:
      secretName: evasion-flag
  restartPolicy: Always
EOF

echo ""
echo "Setup complete. Namespace: $NAMESPACE"
echo ""
echo "The flag is mounted at /secret/flag inside 'red-team-pod'."
echo "Falco is watching for shell spawns (sh, bash, zsh, dash)."
echo "Find a way to read the flag WITHOUT triggering those rules."
echo ""
echo "Start: kubectl exec -n $NAMESPACE red-team-pod -- <your-technique>"
