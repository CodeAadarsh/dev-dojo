#!/usr/bin/env bash
# Plants the skeleton manifests for "Wire the Cluster Autoscaler".
# Idempotent — skeleton files are not overwritten if they already exist.
set -euo pipefail

WORK="$HOME/.kube-dojo-work/04-cluster-autoscaler-wiring"
mkdir -p "$WORK"

if [ ! -f "$WORK/autoscaler.yaml" ]; then
cat > "$WORK/autoscaler.yaml" << 'YAMLEOF'
# Cluster Autoscaler Deployment for EKS (eu-west-1 / dojo-cluster)
# Task: replace --node-group-auto-discovery=TODO with the correct value so the
#       CA can discover the node group tagged in nodegroup.yaml.
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: cluster-autoscaler
  namespace: kube-system
  labels:
    k8s-addon: cluster-autoscaler.addons.k8s.io
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cluster-autoscaler
  namespace: kube-system
  labels:
    app: cluster-autoscaler
spec:
  replicas: 1
  selector:
    matchLabels:
      app: cluster-autoscaler
  template:
    metadata:
      labels:
        app: cluster-autoscaler
      annotations:
        cluster-autoscaler.kubernetes.io/safe-to-evict: "false"
        prometheus.io/scrape: "true"
        prometheus.io/port: "8085"
    spec:
      serviceAccountName: cluster-autoscaler
      priorityClassName: system-cluster-critical
      containers:
        - name: cluster-autoscaler
          image: registry.k8s.io/autoscaling/cluster-autoscaler:v1.30.0
          command:
            - ./cluster-autoscaler
          args:
            - --cloud-provider=aws
            - --namespace=kube-system
            # TODO: replace the value of this flag with the correct auto-discovery spec.
            # Format: asg:tag=<key>=<value>,<key>=<value>
            # The standard keys are:
            #   k8s.io/cluster-autoscaler/enabled=true
            #   k8s.io/cluster-autoscaler/<cluster-name>=owned
            - --node-group-auto-discovery=TODO
            - --balance-similar-node-groups
            - --skip-nodes-with-system-pods=false
            - --expander=least-waste
            - --scale-down-enabled=true
            - --scale-down-unneeded-time=10m
          resources:
            requests:
              cpu: 100m
              memory: 300Mi
            limits:
              cpu: 100m
              memory: 300Mi
          env:
            - name: AWS_REGION
              value: eu-west-1
YAMLEOF
fi

if [ ! -f "$WORK/nodegroup.yaml" ]; then
cat > "$WORK/nodegroup.yaml" << 'YAMLEOF'
# eksctl ClusterConfig — managed node group for dojo-cluster.
# Task 1: set minSize (>= 1) and maxSize (> minSize).
# Task 2: add the two auto-discovery tags so the CA can find this group.
---
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: dojo-cluster
  region: eu-west-1
managedNodeGroups:
  - name: app-workers
    instanceType: m5.large
    amiFamily: AmazonLinux2
    desiredCapacity: 3
    # TODO: set minSize to an integer >= 1
    minSize: 0
    # TODO: set maxSize to an integer > minSize (e.g. 10 gives the CA room to scale)
    maxSize: 0
    labels:
      role: worker
      environment: production
    # TODO: fill in the two auto-discovery tag values so the CA can discover this group.
    #       k8s.io/cluster-autoscaler/enabled   must be "true"
    #       k8s.io/cluster-autoscaler/dojo-cluster  must be "owned"
    tags:
      k8s.io/cluster-autoscaler/enabled: ""
      k8s.io/cluster-autoscaler/dojo-cluster: ""
    iam:
      withAddonPolicies:
        autoScaler: true
YAMLEOF
fi

echo
echo "Work directory : $WORK"
echo
echo "Files:"
echo "  autoscaler.yaml  — Cluster Autoscaler Deployment (fix --node-group-auto-discovery)"
echo "  nodegroup.yaml   — eksctl ClusterConfig (fix minSize, maxSize, and tags)"
echo
echo "Edit both files, then verify:"
echo "  bash courses/course-34-managed-kubernetes/challenges/04-cluster-autoscaler-wiring/verify.sh"
