# Autoscaling on the Cloud

> **Module 05 · Course 34** — On a local kind cluster you can throw pods at a fixed set of nodes. In production you need the *node fleet itself* to respond to demand. This module covers every layer of autoscaling — from the pod metric to the new physical node — and the sharp edges that separate a working autoscaler from one that looks like it's working until Black Friday.

You already know HPA conceptually. This module goes to the level of *why it doesn't scale when you expect it to*, what Karpenter does differently from Cluster Autoscaler, and how to run spot at scale without the pager going off every time AWS reclaims a node.

---

## The autoscaling stack, layered

```
┌──────────────────────────────────────────────────────────────┐
│                       your workload demand                   │
└────────────────────────┬─────────────────────────────────────┘
                         │ too many requests / too high CPU
                         ▼
┌──────────────────────────────────────────────────────────────┐
│  HPA / KEDA (pod-level)                                      │
│  scales Deployment replicas up/down based on metrics         │
└────────────────────────┬─────────────────────────────────────┘
                         │ new pods land Pending (no room)
                         ▼
┌──────────────────────────────────────────────────────────────┐
│  Cluster Autoscaler or Karpenter (node-level)                │
│  provisions / decommissions cloud instances                  │
└──────────────────────────────────────────────────────────────┘
```

VPA (Vertical Pod Autoscaler) fits between HPA and the node layer — it adjusts requests/limits on running pods — but in practice VPA is harder to operationalize safely (it requires pod restarts), so most teams use it in "recommendation mode only" for right-sizing analysis and keep HPA for live scaling.

---

## HPA: beyond CPU

The default `--v1` HPA watches CPU utilization. That's rarely the right signal for modern services. The Kubernetes metrics pipeline supports three sources:

| Source | API group | Typical signal |
|--------|-----------|---------------|
| Resource metrics | `metrics.k8s.io` | CPU%, memory (from metrics-server) |
| Custom metrics | `custom.metrics.k8s.io` | Req/sec, queue depth, active connections (from Prometheus Adapter or KEDA) |
| External metrics | `external.metrics.k8s.io` | SQS queue length, Pub/Sub lag (from KEDA) |

A real-world HPA for a web service:

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: api-server
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: api-server
  minReplicas: 2
  maxReplicas: 50
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 60    # target 60% of requests, not limits
  - type: Pods
    pods:
      metric:
        name: http_requests_per_second
      target:
        type: AverageValue
        averageValue: "200"       # 200 rps/pod before scaling out
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300   # don't scale down for 5 min after load drops
      policies:
      - type: Percent
        value: 10
        periodSeconds: 60         # remove at most 10% of pods per minute on the way down
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
      - type: Pods
        value: 4
        periodSeconds: 60         # add up to 4 pods/min on the way up
```

The `behavior` block is critical in production. Without it, HPA will scale down aggressively after a traffic spike — right before the next one hits — causing the "sawtooth oscillation" you see in most naively-configured clusters.

> **Mental model.** HPA controls *how many pods*. It doesn't provision nodes. Until a new node is available, your new pods sit `Pending`. The pod autoscaler and the node autoscaler have to *agree* on timing — if your HPA fires in 30 seconds but your node takes 3 minutes to warm up, you have a 2.5-minute latency cliff. Pre-warming with `minReplicas` and over-provisioning with "pause pods" (low-priority placeholder pods the node autoscaler over-provisions around) are the standard mitigations.

---

## Scale-from-zero

HPA `minReplicas: 0` is supported but the default metrics server won't give you the signal to scale *up* from zero — by definition there are no pods to report metrics from. KEDA solves this with "external triggers": it watches the queue depth or message backlog directly and scales from zero when the queue is non-empty.

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: worker
spec:
  scaleTargetRef:
    name: worker-deployment
  minReplicaCount: 0
  maxReplicaCount: 20
  triggers:
  - type: aws-sqs-queue
    metadata:
      queueURL: https://sqs.us-east-1.amazonaws.com/123456/jobs
      queueLength: "5"          # scale so each pod handles ≤5 messages
      awsRegion: us-east-1
      identityOwner: operator   # use IRSA/pod identity, not static keys
```

KEDA creates and manages the HPA for you. The `ScaledObject` is your interface.

---

## Cluster Autoscaler

Cluster Autoscaler (CA) watches for `Pending` pods and asks "which node group, if expanded, would allow this pod to schedule?" It then calls the cloud provider's API to add a node, waits for it to join, and the pod schedules.

```
CA loop (every 10s by default):
  1. any Unschedulable pods?  → yes → find expandable node group
  2. call cloud API: increase node group size by N
  3. wait for node Ready
  4. (separately) any underutilized nodes? → evict pods, cordon, terminate
```

Key knobs you'll tune in production:

| Parameter | Default | What it controls |
|-----------|---------|-----------------|
| `--scale-down-utilization-threshold` | 0.5 | A node is a candidate for removal if its requested CPU+mem is below this fraction |
| `--scale-down-delay-after-add` | 10m | Don't try to scale down for N minutes after a scale-up (prevents flip-flop) |
| `--max-node-provision-time` | 15m | If a node doesn't join in this window, CA treats it as failed and tries again |
| `--expander` | `random` | Which node group to pick when multiple could fit: `least-waste`, `priority`, `price` |

The `least-waste` expander is almost always the right choice for cost efficiency — it picks the node group where the new node wastes the least spare capacity. `priority` lets you encode a preference for spot over on-demand by attaching a priority config.

---

## Karpenter: just-in-time nodes

Karpenter is a different mental model. Instead of managing node *groups*, Karpenter watches the pod spec directly and provisions the *exact* instance type that fits — one API call, no node group to resize.

```
CA model:                          Karpenter model:
  node groups (predefined)           NodePool + EC2NodeClass (constraints)
  CA picks a group → resize it       Karpenter reads pending pod reqs →
  node group limits apply              picks best-fit instance → launches it
  scaling bounded by group max         no pre-defined upper bound per type
```

Karpenter's two core objects:

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: default
spec:
  template:
    metadata:
      labels:
        karpenter.sh/nodepool: default
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
      requirements:
      - key: karpenter.sh/capacity-type
        operator: In
        values: ["spot", "on-demand"]
      - key: kubernetes.io/arch
        operator: In
        values: ["amd64"]
      - key: node.kubernetes.io/instance-category
        operator: In
        values: ["c", "m", "r"]  # compute, general, memory: exclude bare metal, GPU
  limits:
    cpu: "1000"
    memory: 2000Gi
  disruption:
    consolidationPolicy: WhenUnderutilized
    consolidateAfter: 30s
```

```yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: default
spec:
  amiFamily: AL2023
  role: KarpenterNodeRole
  subnetSelectorTerms:
  - tags:
      karpenter.sh/discovery: my-cluster
  securityGroupSelectorTerms:
  - tags:
      karpenter.sh/discovery: my-cluster
  blockDeviceMappings:
  - deviceName: /dev/xvda
    ebs:
      volumeSize: 50Gi
      volumeType: gp3
```

**Consolidation** is Karpenter's standout feature. When nodes are underutilized, Karpenter moves pods to fewer nodes and terminates the empties — automatically, without you writing a scale-down policy. Set `consolidateAfter: 30s` for dev and `10m`–`30m` for production (consolidation evicts pods, which causes brief restarts).

> **CA vs Karpenter in a sentence.** CA is a reactive autoscaler for pre-defined node groups — simple, broadly supported, works everywhere. Karpenter is a proactive, instance-type-flexible autoscaler that treats the cloud API as a scheduling primitive — faster, cheaper on spot, but AWS-only (alpha GCP/Azure ports exist) and requires the IAM/IRSA plumbing in CA's role to be set up for a new controller.

---

## Spot / preemptible with interruption handling

Spot gives you 60–90% discount. The trade-off is a 2-minute warning before the node is reclaimed. To run spot safely in production:

**1. Always mix spot with on-demand using weighted node groups (CA) or capacity-type requirements (Karpenter).**

```yaml
# Karpenter: prefer spot, fall back to on-demand
requirements:
- key: karpenter.sh/capacity-type
  operator: In
  values: ["spot", "on-demand"]
```

Karpenter will prefer spot (lower cost) but provision on-demand if spot is unavailable.

**2. Use the Node Termination Handler (NTH) or Karpenter's built-in interruption queue.**

When AWS sends the 2-minute Spot Interruption Notice (SIN), NTH:
- Cordons the node immediately (no new pods land)
- Drains it gracefully (sends SIGTERM to all pods, waits for `terminationGracePeriodSeconds`)

For Karpenter clusters, configure the SQS interruption queue in the controller and Karpenter handles the drain natively — no NTH needed.

**3. Design pods to be interruptible.**

```yaml
spec:
  terminationGracePeriodSeconds: 90   # must be < 120 (the interruption window)
  containers:
  - name: worker
    lifecycle:
      preStop:
        exec:
          command: ["/bin/sh", "-c", "sleep 5"]  # let load balancer drain
```

**4. Use PodDisruptionBudgets to cap simultaneous evictions.**

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: api-server
spec:
  minAvailable: "50%"   # at most half can be down at any instant
  selector:
    matchLabels:
      app: api-server
```

> **War story.** A colleague's Kafka consumer fleet ran 100% spot. Every Tuesday at 3 AM UTC, a large batch job on AWS's side drove spot reclamation in us-east-1c. All three consumer pods landed on nodes in that AZ (no topology spread), the consumer group rebalanced for 4 minutes, and DLQ lag spiked. The fix: `topologySpreadConstraints` to spread pods across AZs + `minAvailable: 1` PDB to guarantee at least one pod survives any drain. Spot is fine; spot without topology awareness is not.

---

## Bin-packing: why your requests hygiene defines your node bill

Every node provisioner (CA or Karpenter) decides how many nodes you need by summing `requests`, not `limits`. A pod with `cpu: requests: 100m` occupies 100m of schedulable capacity regardless of whether it uses 10m at runtime.

```
8-vCPU node:
  system overhead:         ~500m reserved for kubelet + system pods
  schedulable capacity:    7500m

Pod A: requests.cpu=500m → 7500/500 = 15 pods if all were A
Pod B: requests.cpu=2000m → only 3 Bs fit on this node

If you over-request (requests >> actual usage), the scheduler
thinks nodes are full while actual CPU sits at 20%.
Result: CA/Karpenter adds another node → you pay for idle metal.
```

The bin-packing math is why VPA in recommendation mode matters: run VPA for a week, export recommendations, trim `requests` to P95 usage + 20% headroom, and watch your node count drop.

---

## Debugging autoscaling

### Pods Pending with no scale-up

This is the most common failure mode. Diagnose in layers:

```bash
# 1. Confirm pods are truly Unschedulable (not just Starting)
kubectl get pods -A --field-selector=status.phase=Pending
kubectl describe pod <name> | grep -A 10 Events

# 2. Is CA/Karpenter running?
kubectl -n kube-system get pods | grep -E 'cluster-autoscaler|karpenter'
kubectl -n kube-system logs deploy/cluster-autoscaler --tail=50 | grep -i "scale up"

# 3. Check CA's view of node groups
kubectl -n kube-system logs deploy/cluster-autoscaler --tail=200 | grep -E "no.*group|not.*expan|max.*reached"
```

Common CA reasons for "no scale-up":
- **Max node group size reached** — your `maxSize` in the ASG is the hard ceiling; CA won't go above it.
- **No node group can fit the pod** — the pending pod's `nodeSelector`, `affinity`, or `tolerations` rules out every group. Check with `kubectl describe pod` — `MatchNodeSelector` in the Events section is the tell.
- **Pod has a PVC with a `WaitForFirstConsumer` binding mode** — the pod can't be evaluated for scheduling until a node is proposed; it looks Pending to CA but CA won't act until the pod is actually unschedulable (not just waiting for volume binding).
- **CA is in a backoff** — after a failed provision attempt, CA backs off for 5–30 minutes. Look for `backed off` in the logs.

For Karpenter:
```bash
kubectl -n kube-system logs deploy/karpenter --tail=100 | grep -E "launched|failed|insufficient"
kubectl get nodeclaim -A    # see what Karpenter provisioned or failed to provision
kubectl describe nodeclaim <name>
```

### Flapping (scale-up then immediate scale-down)

Symptoms: CA adds a node, the node scales down within minutes, the pod becomes Pending again.

Cause: The pending pod's requests exceed what any new node offers *after* accounting for DaemonSet overhead. CA proposes a node, a DaemonSet pod lands on it (consuming 500m CPU), the remaining capacity is less than the pending pod's request, and CA sees it as underutilized and removes it.

Fix:
```bash
# Simulate what CA sees: subtract DaemonSet requests from node capacity
kubectl get ds -A -o jsonpath='{range .items[*]}{.metadata.name}{" cpu="}{.spec.template.spec.containers[0].resources.requests.cpu}{"\n"}{end}'

# Confirm headroom
kubectl describe node <new-node> | grep -A 10 "Allocated resources"
```

If DaemonSet overhead is the issue, either reduce DaemonSet requests or switch to a larger instance family.

### Spot interruption not handled gracefully

```bash
# Verify NTH or Karpenter interruption handler is installed
kubectl -n kube-system get pods | grep node-termination

# Simulate an interruption (test drain without waiting for AWS)
kubectl cordon <node>
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data --timeout=90s

# Watch pod eviction in real time
kubectl get pods -w -A
```

If pods are stuck in `Terminating` beyond `terminationGracePeriodSeconds`, check for a finalizer holding the pod:
```bash
kubectl get pod <name> -o jsonpath='{.metadata.finalizers}'
```

A stuck finalizer (often from a webhook or storage controller) means the drain will block indefinitely.

---

## Checkpoint

You're ready for the autoscaling challenges when you can, without looking anything up:

1. Describe the three tiers of the autoscaling stack and which layer is responsible for adding physical nodes.
2. Explain why HPA can fire but pods stay `Pending` — and how to close that timing gap in production.
3. Write an HPA manifest for `autoscaling/v2` that targets both CPU utilization and a custom `http_requests_per_second` metric, with a 5-minute scale-down stabilization window.
4. State two fundamental differences between Cluster Autoscaler and Karpenter in terms of what they manage.
5. List the three things that must be true for spot/preemptible to be safe at production scale.
6. Explain, in one sentence, why over-setting `resources.requests` increases your node bill even if CPU usage is low.
7. Diagnose a cluster where pods are `Pending` and CA logs show "no node group can fit" — name two manifest fields that could cause this.
8. Explain what a PodDisruptionBudget guarantees during a spot interruption, and what it cannot guarantee.

➡ Next up: **Cloud Storage & Stateful** — attaching cloud volumes correctly, the AZ trap, and when to run Postgres in-cluster vs hand it to a managed service.
