# Solution — Wire the Cluster Autoscaler

## autoscaler.yaml (complete, passing)

```yaml
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
            - --node-group-auto-discovery=asg:tag=k8s.io/cluster-autoscaler/enabled=true,k8s.io/cluster-autoscaler/dojo-cluster=owned
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
```

### Why each arg matters

**`--node-group-auto-discovery=asg:tag=...`** is the entire connection between the CA process and your cloud node groups. Without it, the CA has no ASGs to manage — it runs but does nothing.

The value `asg:tag=k8s.io/cluster-autoscaler/enabled=true,k8s.io/cluster-autoscaler/dojo-cluster=owned` means: *"find every ASG in this account/region that has BOTH of these tags set to BOTH of these values."* Adding the cluster-name tag (`dojo-cluster=owned`) is essential in multi-cluster accounts — without it, the CA would try to manage node groups belonging to OTHER clusters in the same AWS account, causing cross-cluster interference.

**`--balance-similar-node-groups`** makes the CA spread scale-outs evenly across node groups with identical instance types, which maximises zone distribution without over-complicating your node group configuration.

**`--skip-nodes-with-system-pods=false`** allows the CA to drain nodes even if they host system pods. Set to `true` in environments with host-path-bound critical daemonsets, but `false` is the safer default for general workloads.

**`--expander=least-waste`** chooses the node group that results in the least wasted (unallocated) CPU/RAM after placing the pending pods. It beats the default `random` expander on cost and predictability.

**`cluster-autoscaler.kubernetes.io/safe-to-evict: "false"`** on the CA pod itself prevents the CA from accidentally evicting its own pod during a scale-down — a rare but spectacular failure mode.

---

## nodegroup.yaml (complete, passing)

```yaml
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
    minSize: 2
    maxSize: 10
    labels:
      role: worker
      environment: production
    tags:
      k8s.io/cluster-autoscaler/enabled: "true"
      k8s.io/cluster-autoscaler/dojo-cluster: "owned"
    iam:
      withAddonPolicies:
        autoScaler: true
```

### Why each field matters

**`minSize: 2`** — The CA will never scale below 2 nodes. Setting `minSize: 1` is common for non-critical workloads, but 2 is the minimum for any service that needs to survive a node failure. Setting `minSize: 0` means the CA will drain the group completely when there's no load — dangerous for workloads with a slow cold-start.

**`maxSize: 10`** — The CA will never scale above 10 nodes. This is your cost and capacity ceiling. Choose a value where the maximum pod count can be scheduled (12 pods × 2 pods/m5.large = 6 nodes minimum; 10 gives comfortable headroom) without allowing runaway scaling due to a misconfigured HPA.

**`k8s.io/cluster-autoscaler/enabled: "true"`** — The opt-in tag. The CA's `--node-group-auto-discovery` flag looks for exactly this key-value pair on the ASG. If the value is `"True"` (capitalised) or absent, the CA won't find the group.

**`k8s.io/cluster-autoscaler/dojo-cluster: "owned"`** — The cluster-scoping tag. In an AWS account with multiple EKS clusters, every cluster runs its own CA. Without this tag (matching the `--node-group-auto-discovery` value), each CA would see — and try to manage — every tagged node group in the account. `"owned"` is the conventional value; any non-empty string works, but `"owned"` is what eksctl and the official Helm chart use.

**`iam.withAddonPolicies.autoScaler: true`** — Grants the node's IAM role the `autoscaling:DescribeAutoScalingGroups`, `autoscaling:SetDesiredCapacity`, and related permissions. Without this, the CA can't call the AWS APIs to actually scale the group, even if it correctly discovers it.

---

## Debugging CA wiring

When the CA is running but not scaling, read its logs first:

```bash
kubectl -n kube-system logs -l app=cluster-autoscaler --tail=50 | grep -E "ERROR|No node groups|expander"
```

Common failure patterns:

| Log message | Root cause | Fix |
|-------------|-----------|-----|
| `No node groups found for auto-discovery` | Tag mismatch or `--node-group-auto-discovery` not set | Check ASG tags match the flag exactly (case-sensitive) |
| `Failed to get groups: Unauthorized` | Node IAM role lacks autoscaling permissions | Add `autoScaler: true` to the node group IAM policy |
| `Scale-up done, waiting for nodes to come up` | Nodes are launching but not Ready yet | Normal — wait 2–4 minutes for EC2 to boot and kubelet to register |
| `Node X is not removable, non-daemonset pods present` | Pod has no PDB or `safe-to-evict: true` annotation | Add PDB or annotation to allow eviction |
| CA scales up, immediately scales back down | `--scale-down-unneeded-time` too short, or HPA flapping | Increase `--scale-down-delay-after-add` (default 10 min) |
