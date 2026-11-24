#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="dojo-sec-falco"

echo "==> Setting up: Falco Tripwire"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Simulated Falco alerts — what fired during the attack
kubectl apply -f - << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: falco-simulation
  namespace: dojo-sec-falco
  annotations:
    dojo.challenge/description: "Pre-simulated Falco alerts from an attack on this cluster"
data:
  alerts: |
    {"time":"2026-11-25T10:30:01.234Z","rule":"Terminal shell in container","priority":"Warning","output_fields":{"container.name":"webapp","proc.name":"sh","proc.cmdline":"sh","user.name":"root"},"source":"T1059"}
    {"time":"2026-11-25T10:30:04.891Z","rule":"Read sensitive file trusted after startup","priority":"Warning","output_fields":{"container.name":"webapp","proc.name":"cat","fd.name":"/etc/shadow","user.name":"root"},"source":"T1083"}
    {"time":"2026-11-25T10:30:08.102Z","rule":"Package management processes spawned in container","priority":"Error","output_fields":{"container.name":"webapp","proc.name":"apt","proc.cmdline":"apt install netcat-openbsd","user.name":"root"},"source":"T1072"}
  readme: |
    Three Falco rules fired:
    1. Terminal shell in container — attacker opened /bin/sh (T1059)
    2. Read sensitive file trusted after startup — attacker read /etc/shadow (T1083)
    3. Package management processes — attacker installed netcat (T1072)

    Your task: write a custom rule that would have caught the RECONNAISSANCE
    that happened BEFORE these events (listing binaries with 'ls /usr/bin').
    The default ruleset misses this because 'ls' looks like normal activity.
EOF

kubectl apply -f - << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: rule-hints
  namespace: dojo-sec-falco
data:
  hint: |
    A valid custom Falco rule must have these fields:
      rule: (string — the rule name)
      condition: (Falco condition using evt.type, proc.name, container fields)
      output: (string — the alert message with %field.name% substitutions)
      priority: (WARNING | ERROR | CRITICAL | INFO | DEBUG | NOTICE | ALERT | EMERGENCY)

    To detect 'ls' in a container:
      evt.type = execve      -- captures process execution
      container              -- macro: container.id != host
      proc.name = "ls"       -- the process name
EOF

echo ""
echo "==> Setup complete."
echo ""
echo "    Namespace: $NAMESPACE"
echo "    Simulated alerts: kubectl get configmap falco-simulation -n $NAMESPACE -o jsonpath='{.data.alerts}'"
echo ""
echo "    Your task: write /tmp/custom-falco-rule.yaml with a rule that detects 'ls' in a container"
echo "    Then run: bash verify.sh"
