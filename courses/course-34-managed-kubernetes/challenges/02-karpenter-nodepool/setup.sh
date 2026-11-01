#!/usr/bin/env bash
# Setup for "Karpenter NodePool — Spot + Consolidation".
# Plants NodePool and EC2NodeClass stubs in the learner's work directory.
set -euo pipefail

SLUG="02-karpenter-nodepool"
WORK="$HOME/.kube-dojo-work/$SLUG"

CURRENT_CTX=$(kubectl config current-context 2>/dev/null || echo "none")
if [ "$CURRENT_CTX" != "kind-dojo" ]; then
  echo "Warning: current context is '$CURRENT_CTX', not 'kind-dojo'."
  echo "  This challenge authors cloud manifests — no cluster access needed."
fi

mkdir -p "$WORK"

cat > "$WORK/nodepool.yaml" << 'EOF'
# Challenge: complete this Karpenter v1 NodePool.
# Required:
#   - capacity-type requirement includes 'spot' (and optionally 'on-demand')
#   - spec.limits.cpu set (e.g. "1000")
#   - spec.limits.memory set (e.g. "4000Gi")
#   - spec.disruption.consolidationPolicy set
#   - spec.disruption.consolidateAfter set
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: ml-inference
spec:
  template:
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: ml-inference
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values: ["amd64"]
        # TODO: add capacity-type requirement with spot + on-demand
        # TODO: add instance-category requirement (c, m, r families)
  limits:
    # TODO: set cpu limit (e.g. "1000")
    # TODO: set memory limit (e.g. "4000Gi")
  disruption:
    # TODO: set consolidationPolicy
    # TODO: set consolidateAfter
EOF

cat > "$WORK/ec2nodeclass.yaml" << 'EOF'
# Challenge: complete this EC2NodeClass.
# Required:
#   - spec.amiSelectorTerms has at least one entry
#   - spec.subnetSelectorTerms has at least one entry with tags selector
#   - spec.securityGroupSelectorTerms has at least one entry with tags selector
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: ml-inference
spec:
  # TODO: add amiSelectorTerms (e.g. alias: al2023@latest)
  # TODO: add subnetSelectorTerms (tags selector for your cluster)
  # TODO: add securityGroupSelectorTerms (tags selector for your cluster)
  role: "KarpenterNodeRole-my-cluster"
EOF

echo "Work directory ready: $WORK"
echo ""
echo "Files planted:"
echo "  $WORK/nodepool.yaml       (stub — complete requirements, limits, disruption)"
echo "  $WORK/ec2nodeclass.yaml   (stub — add AMI, subnet, SG selector terms)"
echo ""
echo "Next: edit both files, then run the verifier:"
echo "  bash courses/course-34-managed-kubernetes/challenges/02-karpenter-nodepool/verify.sh"
