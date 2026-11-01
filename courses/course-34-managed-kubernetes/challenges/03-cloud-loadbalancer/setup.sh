#!/usr/bin/env bash
# Setup for "Cloud LoadBalancer — Internal NLB with IP Target Mode".
# Plants a Service stub in the learner's work directory.
set -euo pipefail

SLUG="03-cloud-loadbalancer"
WORK="$HOME/.kube-dojo-work/$SLUG"

CURRENT_CTX=$(kubectl config current-context 2>/dev/null || echo "none")
if [ "$CURRENT_CTX" != "kind-dojo" ]; then
  echo "Warning: current context is '$CURRENT_CTX', not 'kind-dojo'."
  echo "  This challenge authors cloud manifests — no cluster access needed."
fi

mkdir -p "$WORK"

cat > "$WORK/service.yaml" << 'EOF'
# Challenge: add the required AWS Load Balancer Controller annotations.
# Requirements:
#   1. spec.type must be LoadBalancer
#   2. annotation aws-load-balancer-scheme: internal     (not public-facing)
#   3. annotation aws-load-balancer-nlb-target-type: ip  (bypass node kube-proxy)
#   4. annotation aws-load-balancer-cross-zone-load-balancing-enabled: "true"
#   5. annotation aws-load-balancer-type: external       (use AWS LBC, not in-tree)
apiVersion: v1
kind: Service
metadata:
  name: payment-service
  namespace: payments
  annotations:
    # TODO: add the four required annotations
spec:
  # TODO: set type to LoadBalancer
  selector:
    app: payment
  ports:
    - name: grpc
      port: 443
      targetPort: 8443
      protocol: TCP
EOF

echo "Work directory ready: $WORK"
echo ""
echo "Files planted:"
echo "  $WORK/service.yaml   (stub — add annotations and set spec.type)"
echo ""
echo "Next: edit service.yaml, then run the verifier:"
echo "  bash courses/course-34-managed-kubernetes/challenges/03-cloud-loadbalancer/verify.sh"
