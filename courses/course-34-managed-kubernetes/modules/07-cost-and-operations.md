# Cost & Operations

> **Module 07 · Course 34** — Kubernetes makes it easy to spend money. It also makes it easy to hide that spending until your finance team shows you the bill. This module is about the operational discipline that keeps a managed Kubernetes cluster running smoothly over time: right-sizing workloads before they waste money, upgrading clusters without taking down production, managing a fleet of clusters, and building the visibility loop that lets you catch drift before it compounds.

---

## Right-sizing: the requests hygiene problem

The node autoscaler provisions nodes based on `requests`. The actual usage doesn't matter to the scheduler — only the declared requests. This creates a common pattern: teams set generous requests to avoid OOM kills, and end up with 40-node clusters that run at 30% CPU utilization.

**The right-sizing workflow:**

```
1. Install VPA in recommendation mode (no auto-apply)
2. Let it observe for 7–14 days (covers weekly traffic patterns)
3. Export recommendations → compare against current requests
4. Set requests to P95 actual usage + 20% headroom
5. Set limits to 2–3x requests (allow bursting without causing OOM on neighboring pods)
6. Re-run node count estimate: schedulable_capacity / avg_pod_requests
```

VPA recommendation output:
```bash
kubectl get vpa -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}  CPU recommendation: {.status.recommendation.containerRecommendations[0].target.cpu}{"\n"}  Mem recommendation: {.status.recommendation.containerRecommendations[0].target.memory}{"\n\n"}{end}'
```

**Limits vs requests — the production rules:**

| Field | What it does | Production rule |
|-------|-------------|----------------|
| `requests.cpu` | Scheduling weight; guaranteed slice on the node | Set to P95 usage. Under-setting → pod gets throttled on a busy node. Over-setting → wastes schedulable capacity. |
| `limits.cpu` | CPU hard cap (CFS throttle) | Set to 2–3x requests for latency-sensitive services. For batch jobs, omit (let them burst on spare capacity). |
| `requests.memory` | Scheduling weight; *also* the OOM kill threshold for the cgroup | Set close to peak actual usage. Under-setting = OOM kill. |
| `limits.memory` | Hard OOM kill ceiling | Set to requests + 20–30% for stateless services. Equals requests for stateful (no surprise evictions). |

> **Don't copy requests/limits from Stack Overflow.** Every "production-ready" YAML on the internet ships with `requests.cpu: 100m, limits.cpu: 200m`. That fits a hello-world app, not your service. Profile first.

---

## Spot strategy at scale

Running spot/preemptible at >50% of your fleet requires a deliberate strategy, not just setting the capacity type and hoping.

**Capacity diversification is mandatory.** Spot pools are AZ × instance type. If you depend on a single pool (e.g., only `m5.xlarge` in `us-east-1a`), a single reclamation event hits your whole fleet. Diversify:

```yaml
# Karpenter: express "I'll take any of these families in any of these AZs"
requirements:
- key: node.kubernetes.io/instance-type
  operator: In
  values:
  - m5.xlarge
  - m5a.xlarge
  - m5d.xlarge
  - m6i.xlarge
  - m6a.xlarge
- key: topology.kubernetes.io/zone
  operator: In
  values: ["us-east-1a", "us-east-1b", "us-east-1c"]
- key: karpenter.sh/capacity-type
  operator: In
  values: ["spot", "on-demand"]
```

With Karpenter's `price-capacity-optimized` allocation strategy (configurable on the EC2NodeClass), it automatically selects from the cheapest pools with the highest spot availability — better than round-robin.

**On-demand baseline.** Keep at minimum 20–30% of your critical workload on on-demand nodes. Use node affinity + `karpenter.sh/capacity-type` labels to pin critical services:

```yaml
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
      - matchExpressions:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
```

**Interruption metrics to watch.**

```
spot_interruption_rate = (interruptions in 7d) / (node-hours in 7d)
target: < 5%
warning: > 15% → diversify pools
critical: > 30% → add on-demand headroom, review pool mix
```

---

## Cluster upgrades: the correct sequence

Kubernetes releases a minor version every ~4 months. Each version is supported for ~14 months after release. Falling more than 2 minor versions behind means you're blocked from emergency patches.

**The upgrade contract on managed clusters:**

```
EKS, GKE, AKS:
  1. Upgrade the control plane  (managed — you click/CLI, provider does it)
  2. Upgrade node groups one at a time  (roll nodes, pods are evicted/rescheduled)
  Constraint: control plane can be at most 1 minor version ahead of nodes.
  Don't try to skip: 1.28 → 1.30 is blocked by the managed provider.
```

**Pre-upgrade checklist — do this 2 weeks before the window:**

```bash
# 1. Check API deprecations for the target version
kubectl api-resources --verbs=list -o name | xargs -I{} kubectl get {} -A -o yaml 2>/dev/null | grep -i "apiVersion: batch/v1beta1\|apiVersion: networking.k8s.io/v1beta1"
# better: run Pluto (https://github.com/FairwindsOps/pluto) against your cluster
pluto detect-all-in-cluster

# 2. Verify PodDisruptionBudgets won't block node drain
kubectl get pdb -A
# check for minAvailable == total replicas → drain will block forever

# 3. Confirm workloads have ≥2 replicas (single-pod workloads will have downtime during drain)
kubectl get deploy -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}: {.spec.replicas}{"\n"}{end}' | grep ': 1$'

# 4. Test rollback plan: can you downgrade nodes if the upgrade breaks something?
#    Answer: no for control plane (managed; can't downgrade). Yes for nodes: just launch the old AMI.
#    This means your control-plane upgrade is irreversible — run it in staging first.
```

**Node upgrade strategy.**

For Karpenter: update the `EC2NodeClass` AMI reference (or use `amiFamily: AL2023` for auto-selection) + set `expireAfter` on the NodePool:

```yaml
disruption:
  expireAfter: 336h   # force node rotation after 14 days → picks up new AMI
```

For managed node groups (CA): use rolling upgrade with a surge node:

```bash
# EKS managed node group rolling update with max 1 extra node
aws eks update-nodegroup-version \
  --cluster-name my-cluster \
  --nodegroup-name workers \
  --launch-template version="$NEW_VERSION"
# EKS will: add 1 new node, drain 1 old node, delete drained node, repeat
```

> **PDB trap during upgrades.** A team doing a 1.28 → 1.29 upgrade found the node drain hanging for 20 minutes per node. Root cause: a service had `minAvailable: 3` and `replicas: 3` — mathematically, no pod could ever be evicted. The drain command respects PDBs and waits indefinitely rather than violate them. Fix: either increase replicas to 4 before the upgrade, or temporarily patch the PDB. Always audit PDBs before a node drain window.

---

## Multi-cluster / fleet management

Beyond a certain scale (different teams, different regions, different compliance boundaries), you run multiple clusters. The tooling for this:

| Tool | What it solves |
|------|---------------|
| ArgoCD ApplicationSet + cluster generators | Deploy the same application to N clusters; each cluster is a target |
| Flux + Helm repositories | Pull-based multi-cluster GitOps |
| Cluster API (CAPI) | Declare cluster specs in Kubernetes objects; provision/upgrade clusters declaratively |
| Google GKE Fleet / AWS EKS Blueprints | Cloud-native fleet controllers for config sync, identity federation |

The fundamental tension in fleet management: you want uniform policy (same security baseline, same monitoring stack, same network policies) across all clusters, but each cluster has its own load, team, and constraints. The practical answer most teams land on:

1. **A "platform" GitOps repo** that owns infra-level addons (Prometheus, cert-manager, external-dns, CNI config) applied uniformly.
2. **Per-team application repos** that deploy workloads into namespaces; they can't touch cluster-level objects.
3. **A cluster bootstrap process** (often CAPI or Terraform) that provisions a new cluster pre-loaded with the platform addons.

For the SDE-2 interview context: know the difference between *cluster-per-tenant* (strong isolation, higher cost, more ops overhead) vs *namespace-per-tenant* (lower cost, weaker isolation, more complex RBAC). Neither is universally correct — the right answer depends on compliance requirements and trust boundaries.

---

## Observability and cost allocation: Kubecost

Kubernetes doesn't give you per-namespace or per-team cost out of the box. Cloud bills show EC2/GKE instance costs, not which team's pods ran on which nodes. Kubecost (or OpenCost, its OSS core) fills this gap.

Kubecost works by:
1. Reading pod `requests` and actual usage from the metrics server.
2. Mapping pods → nodes → cloud instance costs (via cloud pricing API or a spot price lookup).
3. Allocating node costs proportionally: if your pod requested 1 of 4 vCPUs on a $0.40/hr node, your allocated cost is $0.10/hr.

Key Kubecost reports to review weekly:

```
Cost Allocation by Namespace  → who's spending what
Efficiency Report             → ratio of used / requested (low = over-provisioned)
Savings Recommendations       → right-sizing, cluster bin-packing, orphaned volumes
```

> **Shared costs.** System pods (kube-system, monitoring stack) run on nodes you pay for but don't map to a single tenant. Kubecost lets you distribute idle/shared costs as a percentage overhead per namespace. Agree on an allocation model with your finance team *before* they ask — "we'll bill 10% of cluster cost as shared overhead equally across all teams" is a defensible policy; "TBD" is not.

---

## The FinOps loop

Cost optimization is not a one-time project. Costs drift: new services get deployed with over-provisioned requests, spot strategy decays as pools change, node groups get stale. The discipline is a regular loop:

```
┌─────────────────────────────────────────────────────────────┐
│  Weekly                                                     │
│  Review Kubecost efficiency + new Savings recommendations   │
│  Check spot interruption rate and pool mix                  │
│  Triage "orphaned" PVCs (unbound, paying for idle disk)     │
└─────────────────────────┬───────────────────────────────────┘
                          │ findings
┌─────────────────────────▼───────────────────────────────────┐
│  Monthly                                                    │
│  Run VPA recommendations → update requests in GitOps repo  │
│  Review node group / NodePool sizing (consolidation tuning) │
│  Audit unused LoadBalancers and static IPs (cloud charges   │
│  for idle LBs even when no traffic flows through them)     │
└─────────────────────────┬───────────────────────────────────┘
                          │ structural changes
┌─────────────────────────▼───────────────────────────────────┐
│  Quarterly                                                  │
│  Re-baseline requests/limits against growth in usage        │
│  Review cluster count: can two dev clusters merge?          │
│  Renegotiate reserved instance / committed use discounts    │
└─────────────────────────────────────────────────────────────┘
```

The FinOps loop is the difference between a 40% efficient cluster (typical without active management) and a 70–80% efficient cluster (achievable with the loop running).

---

## Debugging cost and operations

### Idle cost: paying for resources nothing uses

Idle cost is usually one of three things:

**Over-provisioned requests.** Run the VPA + Kubecost efficiency report together:
```bash
# Kubecost efficiency by namespace (requires Kubecost installed)
kubectl port-forward -n kubecost svc/kubecost-cost-analyzer 9090 &
# → http://localhost:9090/allocations

# Without Kubecost: compare requests vs actual via metrics-server
kubectl top pods -A --sort-by=cpu | head -30
kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}: cpu_req={.spec.containers[0].resources.requests.cpu} mem_req={.spec.containers[0].resources.requests.memory}{"\n"}{end}' | head -30
```

**Orphaned PVCs.** A PVC in `Released` state still costs money because the cloud disk exists:
```bash
kubectl get pvc -A --field-selector=status.phase=Released
kubectl get pv | grep Released
# Delete orphaned PVs/PVCs after confirming data is not needed
```

**Idle LoadBalancers.** Cloud LBs are charged per hour even when no traffic flows:
```bash
kubectl get svc -A --field-selector=spec.type=LoadBalancer
# Cross-check with cloud console: are all these actually in use?
```

### Disruptive upgrades: pods evicted during maintenance

If pods are evicted too aggressively during a node upgrade:

```bash
# During a drain, watch which PDB is blocking
kubectl describe node <node-being-drained> | grep -i drain
kubectl get pdb -A

# If drain is stuck, identify the pod blocking it
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data --dry-run 2>&1 | grep -i "cannot evict"
# → "cannot evict pod as it would violate the pod's disruption budget"

# Temporary fix: increase replicas before the maintenance window
kubectl scale deploy <name> --replicas=4

# Permanent fix: ensure minAvailable < replicas in all PDB specs
kubectl get pdb -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}: minAvailable={.spec.minAvailable} maxUnavailable={.spec.maxUnavailable}{"\n"}{end}'
```

### Noisy multi-tenant cost allocation

When multiple teams share a cluster and cost allocation disputes arise:

```bash
# Verify namespace-level resource quotas are set (without quotas, one team can starve others)
kubectl describe namespace <team-ns> | grep -A 10 "Resource Quotas"

# If no quota: set one
kubectl apply -f - <<EOF
apiVersion: v1
kind: ResourceQuota
metadata:
  name: team-a-quota
  namespace: team-a
spec:
  hard:
    requests.cpu: "20"
    requests.memory: 40Gi
    limits.cpu: "40"
    limits.memory: 80Gi
    count/persistentvolumeclaims: "10"
EOF

# LimitRange enforces defaults so pods without requests/limits inherit sensible values
kubectl apply -f - <<EOF
apiVersion: v1
kind: LimitRange
metadata:
  name: team-a-defaults
  namespace: team-a
spec:
  limits:
  - default:
      cpu: "500m"
      memory: "512Mi"
    defaultRequest:
      cpu: "100m"
      memory: "256Mi"
    type: Container
EOF
```

Without `LimitRange`, a pod deployed without requests inherits 0 requested CPU — it schedules anywhere, uses as much as it wants, and doesn't appear in Kubecost's cost allocation correctly. `LimitRange` is the enforcement mechanism that makes cost allocation trustworthy.

> **The multi-tenant cost war.** One team ran a batch job without resource requests. It saturated a shared node, throttled three other teams' latency-sensitive services, and appeared in Kubecost as zero cost allocated to the batch team. The other teams got billed for their degraded SLOs. The fix: `LimitRange` defaults so every pod that doesn't set requests/limits gets sensible defaults automatically, and `ResourceQuota` so no team can blow the cluster budget unilaterally.

---

## Checkpoint

You've completed the managed Kubernetes module track when you can, without looking anything up:

1. Explain why setting `requests.cpu` too high wastes money even if CPU usage is low.
2. Describe the correct order of operations for a managed cluster minor-version upgrade (control plane → nodes, never reversed).
3. Identify two pre-upgrade checks that prevent a node drain from hanging indefinitely.
4. Write a `LimitRange` that sets `cpu: 100m / 256Mi` as default requests for all containers in a namespace.
5. Explain the difference between "idle cost" (unused capacity on running nodes) and "orphaned cost" (resources that exist but have no running workload).
6. Describe what Kubecost measures and how it allocates node costs to namespaces.
7. List three things in the weekly FinOps loop review and two things in the monthly loop.
8. Diagnose a cluster upgrade where `kubectl drain` hangs — name the exact command to identify which pod/PDB is blocking, and the two ways to unblock it.
9. Explain why a pod deployed without `resources.requests` breaks multi-tenant cost accounting in Kubecost.

This is the end of the Managed Kubernetes module track. The challenges that follow put every concept from modules 01–07 into practice: you'll author real cloud manifests for autoscaling, storage, IAM, networking, and cost decisions — all verified offline against structural constraints, not against a live cloud account.
