# Karpenter NodePool — Spot + Consolidation

Your EKS cluster runs batch ML inference jobs. The platform team just installed Karpenter v1.x and deleted the managed node groups. Your on-call shift starts in 10 minutes and the first job is already pending. You need a NodePool that:

- provisions spot nodes to minimize cost, but falls back to on-demand so the job never stalls
- caps cluster spend with hard limits so one runaway job can't spin up 500 nodes
- drains and consolidates idle nodes so you don't pay for warm capacity at 3 AM

No cloud account is required — you author the YAML. `verify.sh` parses it offline.

## Context

`setup.sh` creates a work directory with two stubs:

```
~/.kube-dojo-work/02-karpenter-nodepool/
├── nodepool.yaml        # stub — complete the NodePool spec
└── ec2nodeclass.yaml    # stub — complete the EC2NodeClass spec
```

Both files must be valid Karpenter v1 (`karpenter.sh/v1`) YAML.

## Prerequisites

```bash
pip3 install pyyaml
```

## Background: Karpenter vs Cluster Autoscaler

The Cluster Autoscaler (CA) scales *existing node groups*. You define the group; CA decides how many nodes. This requires pre-defining every instance type you might ever want and managing node group lifecycle separately.

Karpenter replaces the CA model entirely:

```
CA model                          Karpenter model
─────────────────────────────     ──────────────────────────────────────
1. Define node groups             1. Define a NodePool + NodeClass
2. CA scales groups up/down       2. Karpenter picks instance type that fits
3. Instances are fixed types         the pending pod's requirements
4. No awareness of spot markets   3. Spot-first with automatic fallback
                                  4. Consolidation: bins pods onto fewer nodes
                                     and terminates the empty ones
```

The key operational difference: Karpenter **selects the instance type at scheduling time** based on current spot market availability and pod resource requests. You express constraints (max 8 vCPU, no GPU, prefer `m6i` family), and Karpenter picks the cheapest matching instance from the live spot market.

## Karpenter v1 API anatomy

```
karpenter.sh/v1  NodePool
└── spec
    ├── template
    │   └── spec
    │       ├── requirements[]          ← instance constraints (capacity-type, arch, family)
    │       ├── nodeClassRef            ← pointer to EC2NodeClass
    │       └── taints / startupTaints ← optional
    ├── limits                          ← hard cap on total cluster resources
    └── disruption                      ← consolidation + expiry settings

karpenter.k8s.aws/v1  EC2NodeClass
└── spec
    ├── amiSelectorTerms[]              ← which AMI to use
    ├── subnetSelectorTerms[]           ← which subnets to launch into
    └── securityGroupSelectorTerms[]    ← which security groups to attach
```

## Mission

### Step 1 — Complete `nodepool.yaml`

Your NodePool must satisfy all of the following:

| Requirement | What to configure |
|-------------|-------------------|
| Spot **and** on-demand capacity | `requirements`: key `karpenter.k8s.aws/capacity-type`, operator `In`, values `[spot, on-demand]` |
| Hard cpu limit | `spec.limits.cpu` set to a string like `"1000"` (vCPUs) |
| Hard memory limit | `spec.limits.memory` set to a string like `"4000Gi"` |
| Consolidation enabled | `spec.disruption.consolidationPolicy: WhenEmptyOrUnderutilized` **and** `spec.disruption.consolidateAfter: 30s` |
| Prefer smaller instances | `requirements`: key `karpenter.k8s.aws/instance-category`, operator `In`, values `["c", "m", "r"]` |

### Step 2 — Complete `ec2nodeclass.yaml`

Your EC2NodeClass must set:
- `spec.amiSelectorTerms` — at least one entry with `alias: al2023@latest` (or a valid AMI name/id term)
- `spec.subnetSelectorTerms` — at least one entry with a `tags` selector (e.g. `karpenter.sh/discovery: my-cluster`)
- `spec.securityGroupSelectorTerms` — at least one entry with a `tags` selector

## What the verifier checks

```
✓ nodepool.yaml — kind: NodePool, apiVersion: karpenter.sh/v1
✓ capacity-type requirement includes 'spot'
✓ spec.limits.cpu is set
✓ spec.limits.memory is set
✓ spec.disruption.consolidationPolicy is set
✓ spec.disruption.consolidateAfter is set
✓ ec2nodeclass.yaml — kind: EC2NodeClass
✓ spec.amiSelectorTerms has at least one entry
✓ spec.subnetSelectorTerms has at least one entry
✓ spec.securityGroupSelectorTerms has at least one entry
```

## Verify

```bash
bash courses/course-34-managed-kubernetes/challenges/02-karpenter-nodepool/verify.sh
```

All checks pass → flag printed.
