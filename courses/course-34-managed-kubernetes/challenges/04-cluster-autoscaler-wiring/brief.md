# Wire the Cluster Autoscaler

03:14 on a Tuesday. PagerDuty fires: *"47 pods Pending — checkout service degraded."* You open the CA logs and see the same line repeating every 10 seconds:

```
No node groups found for auto-discovery. Check your tags and --node-group-auto-discovery flag.
```

The Cluster Autoscaler is deployed and running. It just doesn't know which node group it owns. Someone shipped the CA deployment with `--node-group-auto-discovery=TODO` and left the node group tags blank. The autoscaler has been running blind for six hours.

Your job: fix both manifests in your work directory so the CA wires up correctly.

## Prerequisites

```bash
python3 -c "import yaml; print('ok')"   # must print "ok"
# if it errors: pip3 install pyyaml
```

No kind cluster required. This challenge verifies the manifests you author on disk.

## Context

`setup.sh` creates a work directory with two skeleton manifests:

```
~/.kube-dojo-work/04-cluster-autoscaler-wiring/
├── autoscaler.yaml   # CA Deployment — has --node-group-auto-discovery=TODO
└── nodegroup.yaml    # eksctl ClusterConfig — minSize=0, maxSize=0, empty tags
```

## How Cluster Autoscaler auto-discovery works

The CA doesn't manage every ASG (Auto Scaling Group) in your account — it discovers only those tagged with specific keys. You tell the CA what to look for via:

```
--node-group-auto-discovery=asg:tag=<key>=<value>,<key>=<value>
```

The standard convention (used by EKS addons, Helm charts, and the official CA docs) is two tags on the ASG:

| Tag key | Tag value | Purpose |
|---------|-----------|---------|
| `k8s.io/cluster-autoscaler/enabled` | `true` | Opt this ASG into CA management |
| `k8s.io/cluster-autoscaler/<cluster-name>` | `owned` | Scope to this specific cluster (prevents cross-cluster interference) |

Both keys must be present in `--node-group-auto-discovery` AND on the node group's tags. That's the wire.

The `minSize` / `maxSize` bounds on the node group are the hard floor and ceiling the CA respects. The CA will never scale below `minSize` (even if pods don't need it) and never above `maxSize`. Setting `maxSize = minSize` locks the group; `maxSize = 0` means the CA configuration is incomplete.

## Mission

Edit the two files in your work directory:

### `autoscaler.yaml`

Find the container `args` list. Replace the `--node-group-auto-discovery=TODO` line with the correct value targeting `dojo-cluster`:

```
--node-group-auto-discovery=asg:tag=k8s.io/cluster-autoscaler/enabled=true,k8s.io/cluster-autoscaler/dojo-cluster=owned
```

### `nodegroup.yaml`

Set three things in the `managedNodeGroups[0]` entry:

1. `minSize` — a non-zero integer (the CA will never drop below this; 1 is the minimum for any HA-critical group, 2–3 is common)
2. `maxSize` — an integer strictly greater than `minSize` (this is where the CA is allowed to grow to under load)
3. Two tags in the `tags:` map:
   - `k8s.io/cluster-autoscaler/enabled: "true"`
   - `k8s.io/cluster-autoscaler/dojo-cluster: "owned"`

## Exact verifier checks

`verify.sh` will pass only when **all** of these hold:

1. `autoscaler.yaml` contains a `Deployment` whose container `args` include `--node-group-auto-discovery` with `k8s.io/cluster-autoscaler/enabled` as a tag key.
2. `nodegroup.yaml` has `managedNodeGroups[0].minSize >= 1`.
3. `nodegroup.yaml` has `managedNodeGroups[0].maxSize > minSize`.
4. `nodegroup.yaml` tags contain `k8s.io/cluster-autoscaler/enabled: "true"`.

## Verify

```bash
bash courses/course-34-managed-kubernetes/challenges/04-cluster-autoscaler-wiring/verify.sh
```

All checks green → flag printed.

## Why this wiring is operationally critical

Without the auto-discovery wire:
- The CA runs but does nothing. Pending pods pile up. Latency climbs. The on-call gets paged.
- This is one of the top-5 "CA is deployed but not scaling" root causes in production EKS clusters.

With the wire set wrong (`minSize = maxSize`):
- The CA can't scale up at all. Same outcome, different root cause.
- A common mistake when an ops team copies a staging config that was intentionally fixed-size.

With `maxSize` set too low:
- The CA scales to max and stops. You get partial relief and an alert you don't understand until you check the CA logs.
