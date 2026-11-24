#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="dojo-sec-gauntlet"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Install Kyverno if not present
if ! kubectl get deployment kyverno -n kyverno >/dev/null 2>&1; then
  echo "Installing Kyverno..."
  helm repo add kyverno https://kyverno.github.io/kyverno/ --force-update
  helm repo update
  helm install kyverno kyverno/kyverno \
    --namespace kyverno --create-namespace \
    --set admissionController.replicas=1 \
    --wait --timeout=5m
  echo "Kyverno installed."
fi

# Store the 5 attack pod specs for reference
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: gauntlet-attacks
  namespace: $NAMESPACE
  annotations:
    dojo.policy/gauntlet: "active"
data:
  attack1_privileged: |
    apiVersion: v1
    kind: Pod
    metadata:
      name: attack1-privileged
      namespace: $NAMESPACE
    spec:
      containers:
      - name: c
        image: alpine:3.20
        securityContext:
          privileged: true
        command: ["sleep", "3600"]
  attack2_hostpath: |
    apiVersion: v1
    kind: Pod
    metadata:
      name: attack2-hostpath
      namespace: $NAMESPACE
    spec:
      containers:
      - name: c
        image: alpine:3.20
        command: ["sleep", "3600"]
        volumeMounts:
        - name: host
          mountPath: /host
      volumes:
      - name: host
        hostPath:
          path: /etc
  attack3_root: |
    apiVersion: v1
    kind: Pod
    metadata:
      name: attack3-root
      namespace: $NAMESPACE
    spec:
      containers:
      - name: c
        image: alpine:3.20
        command: ["sleep", "3600"]
        securityContext:
          runAsUser: 0
          runAsNonRoot: false
  attack4_nolimits: |
    apiVersion: v1
    kind: Pod
    metadata:
      name: attack4-nolimits
      namespace: $NAMESPACE
    spec:
      containers:
      - name: c
        image: alpine:3.20
        command: ["sleep", "3600"]
  attack5_latest: |
    apiVersion: v1
    kind: Pod
    metadata:
      name: attack5-latest
      namespace: $NAMESPACE
    spec:
      containers:
      - name: c
        image: alpine:latest
        command: ["sleep", "3600"]
        resources:
          limits:
            cpu: "100m"
            memory: "64Mi"
        securityContext:
          runAsNonRoot: true
          runAsUser: 1000
EOF

kubectl annotate namespace "$NAMESPACE" dojo.policy/gauntlet=active --overwrite

echo ""
echo "Setup complete. Namespace: $NAMESPACE"
echo "Kyverno is running. No policies applied yet — that's your job."
echo ""
echo "Attack specs are in ConfigMap 'gauntlet-attacks'."
echo "Write a Kyverno ClusterPolicy for each of the 5 attacks, then create the evidence ConfigMap."
