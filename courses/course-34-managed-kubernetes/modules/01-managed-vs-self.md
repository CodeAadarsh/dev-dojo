# Managed vs Self-Managed Kubernetes

> **Module 01 · Course 34** — The first question before any cluster is: *who owns the control plane?* Answering that wrong costs you weeks of surprise toil. This module draws the line, maps the costs, and tells you when crossing back to self-managed is the right call.

The gap between "I know Kubernetes" and "I design Kubernetes infrastructure" is largely about understanding what the cloud vendor hides from you and what it hides *on purpose*. Skip this mental model and you will debug the wrong layer for months.

---

## Control-plane-as-a-service

In a managed cluster, the three components that constitute the Kubernetes control plane — `kube-apiserver`, `etcd`, and `kube-scheduler`/`kube-controller-manager` — run in the cloud provider's infrastructure, not on nodes you see or pay for directly.

```
┌──────────────────────────── Cloud Provider Account ──────────────────────────────┐
│                                                                                    │
│   ┌──── MANAGED CONTROL PLANE ─────────────────────────────────────────────────┐  │
│   │  kube-apiserver (HA, multi-AZ)  │  etcd (HA, encrypted at rest)           │  │
│   │  kube-scheduler                 │  kube-controller-manager                 │  │
│   │  cloud-controller-manager       │  admission webhooks (optional)          │  │
│   │  [you see: an endpoint URL]     │  [you see: nothing; can't ssh in]       │  │
│   └─────────────────────────────────────────────────────────────────────────────┘  │
│                                  ↕  API calls only                                 │
│   ┌─── YOUR VPC ─────────────────────────────────────────────────────────────────┐ │
│   │   node-group-a (us-east-1a)    node-group-b (us-east-1b)                    │ │
│   │   ┌────────────┐  ┌──────┐    ┌────────────┐  ┌──────┐                      │ │
│   │   │  kubelet   │  │ pods │    │  kubelet   │  │ pods │   ← YOU OWN THIS    │ │
│   │   │  kube-proxy│  │      │    │  kube-proxy│  │      │                      │ │
│   │   └────────────┘  └──────┘    └────────────┘  └──────┘                      │ │
│   └──────────────────────────────────────────────────────────────────────────────┘ │
└────────────────────────────────────────────────────────────────────────────────────┘
```

What each major provider offers:

| Provider | Service | Control-plane cost |
|----------|---------|-------------------|
| AWS      | EKS     | $0.10/hr per cluster (~$73/month) |
| Google   | GKE     | Free (Standard); $0.10/hr (Enterprise) |
| Azure    | AKS     | Free control plane; pay for nodes only |
| Rancher/Talos | Self-managed | Your infra + your ops time |

The control-plane fee is a fixed charge per cluster per hour, independent of node count. At five clusters, EKS control-plane cost alone is $365/month before a single EC2 instance.

---

## What the cloud runs — what you run

The shared-responsibility split is not merely operational; it determines your blast radius and your debugging surface.

**Cloud vendor runs:**
- etcd (multi-AZ quorum, automatic backup, encryption at rest)
- `kube-apiserver` (HA load-balanced endpoint, TLS cert rotation, audit logging sent to cloud logs)
- `kube-scheduler` and `kube-controller-manager`
- Kubernetes version upgrades of the control plane (when you trigger them)
- The cloud-controller-manager that reconciles LoadBalancers, NodeCIDRs, etc.

**You run:**
- Worker nodes (EC2/Compute/VMs): OS patching, kubelet version, EBS drivers
- Node groups and autoscaling config
- Networking layer within your VPC (CNI plugin, Security Groups, subnets)
- All workloads, RBAC policies, NetworkPolicies, admission webhooks
- Add-ons co-managed with the cloud (CoreDNS, kube-proxy, VPC CNI on EKS)
- Node OS upgrades (Amazon Linux, Ubuntu, COS on GKE)

The catch with co-managed add-ons: when you upgrade the cluster, the cloud may upgrade the add-on version, potentially overwriting a customization you applied directly to the add-on's ConfigMap. Always manage add-on config through the vendor's add-on API, not `kubectl edit`.

---

## Shared responsibility in practice

```
                CLOUD MANAGES ←─────────────────────────────→ YOU MANAGE
                                                                            
  Control plane ██████████████████████████░░░░░░░░░░░░░░░░░░ Audit log config
  etcd backup   ████████████████████████░░░░░░░░░░░░░░░░░░░░ Retention window
  Node OS       ░░░░░░░░░░░░░░░░░░░░░░░░████████████████████ Patching cadence
  Kubelet       ░░░░░░░░░░░░░░░░░░░░░░░░████████████████████ Version pin
  Networking    ░░░░░░░░░░░░░░░░░░░░░░░░████████████████████ CIDR sizing, SGs
  IAM for nodes ████████████████████░░░░░░░░░░░░░░░░░░░░░░░░ Role scope (your CVE)
  K8s upgrades  ████████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ Scheduling the window
```

IAM for nodes is a common trap: the cloud creates the node IAM role, but *you* scope the policies. An over-broad node role is your bug, not the cloud's.

---

## Cost model

A realistic EKS cluster cost breakdown for a small production environment:

| Component | Monthly cost (rough) |
|-----------|---------------------|
| EKS control plane (1 cluster) | $73 |
| 3× m5.large nodes (on-demand) | ~$180 |
| NAT Gateway (1 AZ) | ~$45 |
| Load Balancer (1 NLB) | ~$20 |
| Data transfer (cross-AZ) | variable — often the surprise |
| **Total** | **~$320+** |

Cross-AZ traffic is the bill shock that hits at scale. EKS, GKE, and AKS all charge $0.01–$0.02/GB for traffic crossing availability zones, which means a pod on node-a reading from a DB pod on node-b burns money on every request. This drives the topology-spread and zone-aware routing discussions in Module 04.

GKE Autopilot changes the model: you pay per pod CPU/memory, not per node. There are no nodes to manage, but you give up node-level debugging and custom kernel tuning.

---

## Version and upgrade cadence

Managed clusters generally track upstream Kubernetes with a 2–4 week delay per minor version. Each provider end-of-lifes minor versions on a rolling basis.

| Provider | Supported minor versions | Auto-upgrade option |
|----------|--------------------------|---------------------|
| EKS | ~4 minor versions at once | Managed node group auto-update |
| GKE | ~3 minor versions (Release channels) | Automatic (Rapid/Regular/Stable) |
| AKS | ~3 minor versions | Auto-upgrade channels (patch, stable, rapid) |

**Version skew rule (unchanged from vanilla K8s):** kubelet must not be more than two minor versions behind the API server. Cloud upgrades the control plane first; if your node group lags behind by three minors, `kubectl` will show you nodes as unsupported.

GKE's Release Channels (Rapid / Regular / Stable) are the cleanest abstraction for most teams: pin to `REGULAR` and you get upgrades after they have been validated in `RAPID` for a week.

---

## When self-managed still makes sense

Managed K8s is the right default for 90% of teams. The remaining 10%:

1. **Air-gapped / regulated environments** — FISMA, IL5, or a data centre with no cloud egress. Rancher, k3s, or Talos in a bare-metal colo.
2. **Exotic hardware** — GPU node pools with custom drivers not in the managed AMI catalogue, or bare-metal for DPDK networking.
3. **Cost at extreme scale** — above ~500 nodes, the EC2 savings from reserved or spot instances plus eliminated per-cluster fees can justify a dedicated platform team. Shopify, Cloudflare, and others run at this scale.
4. **Multi-cloud portability as a hard requirement** — ClusterAPI or Crossplane gives you a single IaC surface. Still possible with EKS/GKE/AKS, but it adds abstraction layers.
5. **Control plane customization** — custom scheduler plugins, admission webhooks that need control-plane co-location, or etcd tuning for very high write throughput (>10 000 writes/sec).

The honest SDE-2 answer is: "we use EKS because the control-plane toil is real and we don't have an infra team large enough to own it." That is a correct answer.

---

## Debugging: control-plane limits you can't see

The most disorienting part of managed K8s is debugging failures in a component you cannot `exec` into or read logs from directly.

### API server throttling

EKS and GKE throttle API server requests. When you have hundreds of controllers, operators, or badly behaved CDRs all hitting the API at once, you will see:

```
Error from server: etcdserver: request timed out
Unable to connect to the server: dial tcp: connection refused
```

These are not node failures. Check:

```bash
# EKS: API server request rate from CloudWatch
aws cloudwatch get-metric-data \
  --metric-name apiserver_request_total \
  --namespace "containerinsights/<cluster>/prometheus" ...

# GKE: visible in Cloud Monitoring under k8s.io/apiserver/...
# AKS: Azure Monitor → Insights → API Server

# On any provider — look for 429s or server-side throttle in client QPS:
kubectl get --raw /metrics | grep apiserver_request_total
```

If `kubectl` itself is slow, the problem is upstream of your pods. Reduce controller polling intervals, set `resyncPeriod` on informers, and use watch (not poll) in custom operators.

### Upgrade surprises

The two most common post-upgrade breakages:

1. **Deprecated API versions removed.** K8s removes beta APIs on a schedule (e.g., `apps/v1beta2` removed in 1.16, `networking.k8s.io/v1beta1` Ingress in 1.22). The cloud upgrades the API server; your Helm releases still reference the old GV/K; they break silently or refuse to apply.

```bash
# Before upgrading: audit deprecated API usage
kubectl api-resources --verbs=list --namespaced -o name | xargs -I{} kubectl get {} --all-namespaces -o jsonpath='{range .items[*]}{.apiVersion}{"\t"}{.kind}{"\n"}{end}' 2>/dev/null | sort -u

# Pluto is the purpose-built tool (install once):
pluto detect-all-in-cluster --target-versions k8s=v1.28
```

2. **Add-on version pinned to old K8s version.** CoreDNS or kube-proxy on EKS is a managed add-on. After a control-plane upgrade from 1.27→1.28, if the add-on version wasn't also bumped, you can land on an unsupported combination.

```bash
# EKS: check add-on versions
aws eks describe-addon --cluster-name CLUSTER --addon-name coredns
aws eks list-addons --cluster-name CLUSTER

# Update an add-on to the recommended version for the new cluster version:
aws eks update-addon --cluster-name CLUSTER --addon-name coredns \
  --addon-version $(aws eks describe-addon-versions --kubernetes-version 1.28 \
    --addon-name coredns --query 'addons[0].addonVersions[0].addonVersion' --output text)
```

### Audit log — your only window into the control plane

When something breaks at the API layer and you cannot see the control plane, the audit log is your only evidence. All three major providers route it to their logging service:

```bash
# EKS → CloudWatch Logs /aws/eks/<cluster>/cluster → log group "kube-apiserver-audit"
aws logs filter-log-events \
  --log-group-name /aws/eks/my-cluster/cluster \
  --filter-pattern '"verb":"delete"' \
  --start-time $(($(date +%s) - 3600))000

# GKE → Cloud Audit Logs → resource.type="k8s_cluster"
# AKS → Azure Monitor → AKSDiagnosticLogs → kube-audit
```

Enable audit logging before you need it — enabling it on a running cluster takes 5–10 minutes and logs nothing retroactively.

---

## Checkpoint

You are ready for the next module when you can answer these without looking up:

1. Name the three control-plane components a managed K8s service runs for you. Where do you go to debug them if something goes wrong?
2. Which IAM component does the cloud create but you scope — and why is an over-broad one a CVE, not just a config mistake?
3. A pod on node-a is sending 50 GB/day to a pod on node-b in a different AZ. Estimate the monthly AWS bill for that traffic alone.
4. You upgrade EKS from 1.27 to 1.28. Your Helm-deployed Ingress immediately fails `kubectl apply`. What is the first thing you check?
5. Give two concrete reasons a startup with three engineers should use EKS instead of running their own control plane.
6. Give one concrete reason a 500-engineer company might leave EKS for a self-managed cluster.

➡ Next up: **Provisioning Clusters** — eksctl, node pools vs node groups, and Terraform for cluster lifecycle.
