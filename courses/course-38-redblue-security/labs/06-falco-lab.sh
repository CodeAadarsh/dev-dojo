#!/usr/bin/env bash
# Module 06 — Runtime Detection with Falco Lab
# Installs Falco and creates a target pod for running attack exercises
set -euo pipefail

NS="dojo-lab-falco"

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

# Install Falco if not present
if ! helm list -n falco | grep -q "^falco"; then
  echo "Installing Falco via Helm..."
  helm repo add falcosecurity https://falcosecurity.github.io/charts --force-update
  helm repo update

  helm install falco falcosecurity/falco \
    --namespace falco \
    --create-namespace \
    --set driver.kind=modern_ebpf \
    --set falco.grpc.enabled=true \
    --set falco.grpcOutput.enabled=true \
    --set tty=true \
    --wait --timeout=5m
  echo "Falco installed."
else
  echo "Falco already installed."
fi

kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: target-pod
  namespace: $NS
  labels:
    app: target
spec:
  containers:
  - name: target
    image: alpine:3.20
    command: ["sh", "-c", "sleep 86400"]
    resources:
      limits:
        cpu: "200m"
        memory: "128Mi"
  restartPolicy: Always
EOF

echo "Falco lab ready. Namespace: $NS"
echo ""
echo "Watch Falco alerts in real time:"
echo "  kubectl logs -n falco -l app.kubernetes.io/name=falco -f | grep -v '^$'"
echo ""
echo "Attack exercises (should trigger Falco alerts):"
echo "  # Terminal shell in container:"
echo "  kubectl exec target-pod -n $NS -- sh -i"
echo ""
echo "  # Write to /etc:"
echo "  kubectl exec target-pod -n $NS -- sh -c 'touch /etc/evil'"
echo ""
echo "  # Read sensitive files:"
echo "  kubectl exec target-pod -n $NS -- sh -c 'cat /etc/shadow'"
echo ""
echo "  # What DOESN'T trigger the shell rule (evasion):"
echo "  kubectl exec target-pod -n $NS -- python3 -c 'print(\"no shell alert\")'"
