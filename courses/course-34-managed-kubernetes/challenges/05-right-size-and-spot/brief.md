# Right-size + Spot: FinOps on EKS

Your FinOps platform sends a weekly digest. This week's top finding:

> **Cluster `prod-eu` — compute spend $560/month**
> CPU utilization: 41.7% · RAM utilization: 20.8%
> Recommendation: right-size node type and introduce spot instances.

The on-call manager asks: "How much do we actually save?" You open the scenario, do the math, and write the answer.

## Context

`setup.sh` creates a work directory:

```
~/.kube-dojo-work/05-right-size-and-spot/
├── scenario.md    # workload spec + pricing table + formula guide
├── answers.py     # fill in three variables
└── checker.py     # validates your answers within ±10%
```

## Prerequisites

Python 3 in `PATH`. No packages.

## The Scenario

`api-workers` — stateless REST API handlers.

**Workload:**

| Parameter | Value |
|-----------|-------|
| Replicas | 12 |
| CPU request per pod | 500m (0.5 vCPU) |
| RAM request per pod | 1 GiB |

**Current cluster (all on-demand):**

| Node type | vCPU | RAM | On-demand price |
|-----------|------|-----|-----------------|
| `m5.2xlarge` | 8 | 32 GiB | $0.384/hr |
| Nodes in cluster | 2 | — | — |

Kubernetes reserves ~10% of each node's resources for system components. Effective allocatable per node: **7.2 vCPU / 28.8 GiB**.

**Right-sized option (on-demand):**

| Node type | vCPU | RAM | On-demand price |
|-----------|------|-----|-----------------|
| `m5.large` | 2 | 8 GiB | $0.096/hr |

Effective allocatable per m5.large: **1.8 vCPU / 7.2 GiB**.

**Spot price for m5.large:** $0.029/hr (stable eu-west-1 spot history; use this exact figure).

**Billing:** 730 hours per month (AWS standard month).

## Mission

Open `answers.py` and compute the three cost figures:

```python
current_monthly_cost    = 0.0   # $USD — current 2× m5.2xlarge, on-demand, 730 h
rightsized_monthly_cost = 0.0   # $USD — right-sized to on-demand m5.large only
mixed_monthly_cost      = 0.0   # $USD — right-sized, 50% on-demand + 50% spot m5.large
```

`checker.py` imports `answers.py` and validates each value within **±10%** of the reference figure.

## How to derive each figure

Work through `scenario.md` in your work directory for the step-by-step formulas. The key insight is pod density:

```
pods_per_node = min(floor(allocatable_cpu / cpu_request),
                    floor(allocatable_ram / ram_request))
nodes_needed  = ceil(replicas / pods_per_node)
monthly_cost  = nodes_needed × price_per_hour × 730
```

For the mixed case, round `nodes_needed / 2` to the nearest integer for each tier.

## Verify

```bash
bash courses/course-34-managed-kubernetes/challenges/05-right-size-and-spot/verify.sh
```

All three estimates within ±10% → flag printed.

## Why this arithmetic matters in interviews and real work

Right-sizing + spot is the single highest-leverage cost-reduction move in managed Kubernetes. But interviewers and engineering managers care about the *derivation*, not a tool output.

The three derived numbers directly drive real decisions:
- **Current cost** — establishes the baseline; without it you can't measure the impact of any change.
- **Right-sized on-demand cost** — isolates the node-type savings from the spot savings. In practice, right-sizing alone often saves 30–50% and involves zero availability risk.
- **Mixed cost** — the additional savings from spot. Spot can be interrupted with 2-minute notice; the right mitigation is running spot alongside at least 1 on-demand node (so one interruption doesn't take the whole fleet) — which is exactly the 50% split in this scenario.
