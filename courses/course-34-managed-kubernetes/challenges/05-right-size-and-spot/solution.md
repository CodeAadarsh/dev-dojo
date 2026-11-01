# Solution — Right-size + Spot

## Step 1 — current cluster baseline

2× `m5.2xlarge` at $0.384/hr, billed for 730 hours/month:

```
current_monthly_cost = 2 × $0.384 × 730
                     = $0.768 × 730
                     = $560.64
```

CPU utilization: 12 pods × 0.5 vCPU = 6 vCPU used / (2 × 7.2 = 14.4 vCPU available) = **41.7%**
RAM utilization: 12 pods × 1 GiB = 12 GiB used / (2 × 28.8 = 57.6 GiB available) = **20.8%**

Both are well below 50%. The nodes are over-provisioned.

## Step 2 — right-sizing: compute pod density on m5.large

`m5.large`: 2 vCPU, 8 GiB RAM, 10% reserved for system components.

```
allocatable_cpu = 2 × 0.9 = 1.8 vCPU
allocatable_ram = 8 × 0.9 = 7.2 GiB

pods_per_node_cpu = floor(1.8 / 0.5) = floor(3.6) = 3
pods_per_node_ram = floor(7.2 / 1.0) = floor(7.2) = 7
pods_per_node     = min(3, 7) = 3   ← CPU is the binding constraint
```

The m5.large is CPU-bound for this workload. Each node holds 3 pods.

```
nodes_needed = ceil(12 / 3) = ceil(4.0) = 4
```

On-demand monthly cost:

```
rightsized_monthly_cost = 4 × $0.096 × 730
                        = $0.384 × 730
                        = $280.32
```

Savings vs current: $560.64 − $280.32 = **$280.32 (50%)** — just from choosing the right node type.

## Step 3 — mixed: add 50% spot

Split the 4 nodes evenly: 2 on-demand + 2 spot.

```
nodes_on_demand = ceil(4 / 2) = 2
nodes_spot      = 4 − 2 = 2

monthly_on_demand = 2 × $0.096 × 730 = $140.16
monthly_spot      = 2 × $0.029 × 730 =  $42.34
mixed_monthly_cost = $140.16 + $42.34 = $182.50
```

Total savings vs original: $560.64 − $182.50 = **$378.14 (67.5%)**.

## The answers.py solution

```python
current_monthly_cost    = 560.64
rightsized_monthly_cost = 280.32
mixed_monthly_cost      = 182.50
```

## Why right-sizing saved 50% without touching spot

The m5.2xlarge costs 4× more than the m5.large ($0.384 vs $0.096), but our workload is CPU-constrained at 3 pods/node on both types. The workload doesn't use the extra RAM or the extra CPU cores of the larger instance — they sit idle.

**Rule of thumb:** when your pod's CPU:RAM ratio is ~1:2 (e.g., 0.5 vCPU : 1 GiB), choose a node type with a similar ratio. The m5 family is 1:4 (vCPU:GiB). This always leaves RAM stranded when the workload is CPU-light. For CPU-bound workloads, `c5` (compute-optimised, ~1:2 ratio) or right-sized `m5.large` both work better. For memory-bound workloads, `r5` (1:8) would be the direction.

## Spot risk: what you're accepting

Spot instances can be interrupted with 2 minutes notice. Mitigations already embedded in this scenario:

1. **50/50 split** — an interruption takes at most half the fleet. The 2 surviving on-demand nodes hold 6/12 pods. Combined with a fast HPA response, the service degrades gracefully rather than going down.
2. **Stateless workload** — `api-workers` has no local state. A terminated pod is replaced immediately by the scheduler.
3. **Multi-AZ spread** — both node groups should span at least 2 AZs; a spot interruption in one AZ is usually zone-scoped.

For stateful workloads (databases, session-coupled services), don't run the primary replica on spot. Use spot for read replicas or batch jobs only.

## Common mistakes in FinOps interviews

| Mistake | Consequence |
|---------|-------------|
| Forgetting the 10% system overhead | Pod density comes out 10% too high; you under-provision and pods go Pending |
| Using 720 h/month instead of 730 | 1.4% error — within tolerance, but use 730 for AWS billing accuracy |
| Mixing on-demand and spot prices when quoting "spot savings" | Creates an apples-to-oranges comparison; always anchor to the same node type's on-demand price |
| Not checking which resource is the binding constraint (CPU vs RAM) | Can lead to choosing a node type that's under-provisioned on the wrong axis |
