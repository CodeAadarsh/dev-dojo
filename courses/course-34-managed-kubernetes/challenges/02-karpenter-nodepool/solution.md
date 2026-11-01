# Solution — Karpenter NodePool — Spot + Consolidation

The flag is `KUBE{karpenter_spot_plus_consolidation}`.

## Complete `nodepool.yaml`

```yaml
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
        - key: karpenter.k8s.aws/capacity-type
          operator: In
          values: ["spot", "on-demand"]
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["c", "m", "r"]
        - key: karpenter.k8s.aws/instance-generation
          operator: Gt
          values: ["5"]
  limits:
    cpu: "1000"
    memory: "4000Gi"
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 30s
```

## Complete `ec2nodeclass.yaml`

```yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: ml-inference
spec:
  amiSelectorTerms:
    - alias: al2023@latest
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: "my-cluster"
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: "my-cluster"
  role: "KarpenterNodeRole-my-cluster"
```

## Why each field matters

### `capacity-type: [spot, on-demand]`

Karpenter uses the order of preference in your fleet. With both in the list, Karpenter tries spot first (always cheaper) and falls back to on-demand when spot capacity is unavailable or spot interruption risk is high. **Do not list only spot** — an interruption storm will leave all your jobs pending with no fallback.

### `spec.limits`

Without limits, a single misbehaving HPA + no pod budget can autoscale to hundreds of nodes before anyone notices. Limits are a hard ceiling on total vCPU and memory *Karpenter* can provision — not the cluster total, just this NodePool's share. Set them to ~2–3× your expected peak.

```
# Real cost consequence of no limits:
# 200 x m6i.2xlarge (8vCPU, 32Gi) = 1600 vCPU, ~$19/hr at on-demand price
# With limits.cpu: "200" that's caught at node #26
```

### `consolidationPolicy: WhenEmptyOrUnderutilized`

| Policy | Behavior |
|--------|----------|
| `WhenEmpty` | Terminates nodes only when **zero** pods are running on them |
| `WhenEmptyOrUnderutilized` | Also bins packs pods from underloaded nodes and terminates the now-empty ones |

`WhenEmptyOrUnderutilized` is almost always what you want for batch workloads. The runtime overhead is a pod disruption event (respects PDBs), which for ML inference jobs is acceptable. For stateful workloads (databases), use `WhenEmpty` or exclude them from the NodePool entirely with a separate one that has `consolidationPolicy: WhenEmpty`.

### `consolidateAfter: 30s`

How long an empty-or-underutilized node must stay idle before Karpenter terminates it. 30s is aggressive but fine for stateless inference workers. For services that have slow warm-up (JVM, model load), set it higher (300s) to avoid repeated cold-start churn.

### `instance-generation: Gt 5`

Filters out instance families older than generation 5 (e.g. excludes `m5`, targets `m6i`, `m7i`). Newer generations offer better price/performance and are available on spot more reliably.

## Common mistakes

| Mistake | Consequence |
|---------|-------------|
| Only listing `spot` in capacity-type | Jobs stall during spot interruption storms |
| Forgetting `spec.limits` | A runaway autoscaler scales to hundreds of nodes before alerting |
| Using `WhenEmpty` for batch jobs | Nodes stay warm indefinitely, costing money at 3 AM |
| Mismatching `name` between NodePool's `nodeClassRef.name` and EC2NodeClass `metadata.name` | Karpenter can't provision any node; pods remain Pending |
| No `instance-generation` constraint | Old gen instances (`c3`, `m4`) win on spot price but have worse perf/dollar ratio |

## Operational follow-up: Disruption budgets

Karpenter respects Pod Disruption Budgets during consolidation. Without a PDB, it can terminate multiple pods simultaneously. For the inference service:

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: ml-inference-pdb
spec:
  maxUnavailable: 1
  selector:
    matchLabels:
      app: ml-trainer
```

This ensures consolidation terminates at most one pod at a time — the job finishes, then the node drains.
