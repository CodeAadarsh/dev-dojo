# Storage: CSI, PV, PVC & StorageClasses

> **Module 02 · Course 08** — The `volumeClaimTemplates` in the last module asked for a `1Gi ReadWriteOnce` volume and got one. What actually happened? A StorageClass provisioner created a PersistentVolume, a PersistentVolumeClaim bound to it, and a kubelet on the scheduled node mounted it into the container. That four-step binding chain has exactly four places to fail. This module makes each step transparent and gives you the diagnostic playbook for all of them.

---

## The binding chain

Every mounted volume travels through the same chain. Internalize this diagram — every storage error maps to one link in it.

```
Pod spec
  └── volumeMounts[name=data]
        └── volumes[name=data].persistentVolumeClaim.claimName: "data-web-0"
              └── PersistentVolumeClaim "data-web-0"   (namespace-scoped, your request)
                    └── (bound to) PersistentVolume "pvc-abc123..."   (cluster-scoped, actual disk)
                              └── (provisioned by) StorageClass "standard"
                                        └── (driver) rancher.io/local-path
```

Two paths to a bound PVC:

**Dynamic provisioning (the default in real clusters):**
1. PVC is created referencing a StorageClass name.
2. The StorageClass's provisioner (a controller pod) calls the CSI driver's `CreateVolume`.
3. The provisioner creates a PV object and sets its `claimRef` to the PVC.
4. The PVC controller sees a matching PV and sets `status.phase: Bound` on both.
5. kubelet calls the CSI node plugin's `NodePublishVolume` to mount the PV into the pod.

**Static provisioning (legacy / dedicated hardware):**
1. An admin pre-creates PV objects (NFS exports, iSCSI LUNs, local disks).
2. A PVC is created; the bind controller matches it to a PV by capacity, access mode, and `storageClassName`.
3. Same mount step as above.

With dynamic provisioning you never create PVs manually. The StorageClass is the only knob you turn.

---

## Access modes — nodes, not pods

Access modes describe how many **nodes** can mount the volume simultaneously (not pods — this distinction matters):

| Mode | Short | What it means | Typical backend |
|------|-------|---------------|----------------|
| `ReadWriteOnce` | RWO | One node can mount read-write | local disk, cloud block (EBS, GCP-PD) |
| `ReadOnlyMany` | ROX | Many nodes can mount read-only | NFS, object-backed storage |
| `ReadWriteMany` | RWX | Many nodes can mount read-write | NFS, CephFS, AWS EFS |
| `ReadWriteOncePod` | RWOP | Only one *pod* (not just one node) can mount | strong exclusivity, Kubernetes 1.22+ |

> **The common misconception.** RWO means "one node," not "one pod." Two pods scheduled to the same node can both mount an RWO volume. If you need exclusive single-pod access — e.g., to prevent two database replicas from ever sharing a disk even on the same node — use RWOP. For databases running on their own dedicated node (which is the right setup via anti-affinity), RWO is almost always correct: it's widely supported and maps cleanly to block storage semantics.

Check what access modes a StorageClass's driver actually supports:

```bash
kubectl describe sc standard | grep -A5 'Provisioner\|Parameters'
# then check the CSI driver's documentation — kind's local-path supports RWO only
```

---

## Reclaim policies

What happens to a PV when the PVC that bound it is deleted?

| Policy | Behavior | When to use |
|--------|----------|------------|
| `Retain` | PV moves to `Released` state; backing storage survives; admin must manually reclaim or rebind | Production data you cannot afford to auto-delete; the safe default for stateful workloads |
| `Delete` | PV object and its backing storage are deleted automatically | Dev clusters, throwaway scratch volumes, CI pipelines |
| `Recycle` | (Deprecated) performs `rm -rf` and re-offers the PV | Do not use — use dynamic provisioning instead |

The reclaim policy is set on the StorageClass (affects all dynamically provisioned PVs from it) or overridden per PV:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: standard-retain
provisioner: rancher.io/local-path
reclaimPolicy: Retain                    # safer default for stateful data
volumeBindingMode: WaitForFirstConsumer
```

Patch the policy on an existing PV before deleting a PVC (if you realize you forgot Retain):

```bash
kubectl patch pv pvc-abc123 \
  -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
# do this BEFORE deleting the PVC; once the PVC is gone and policy is Delete, the PV is also gone
```

After deleting the PVC on a `Retain` PV:

```bash
kubectl get pv pvc-abc123
# STATUS: Released  (no longer bound, but data is safe)
# To rebind: remove .spec.claimRef from the PV, then create a new PVC that matches it
kubectl patch pv pvc-abc123 --type=json \
  -p '[{"op":"remove","path":"/spec/claimRef"}]'
# PV moves to Available; a new PVC can bind to it
```

---

## Dynamic provisioning and StorageClasses

A StorageClass is the factory spec: provisioner + parameters + reclaim policy + binding mode. Creating one is enough; the provisioner does the rest.

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: fast
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"  # makes this the default
provisioner: rancher.io/local-path
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: false
```

PVCs that omit `storageClassName` get the default class. If there is no default class, those PVCs stay `Pending` forever (no error, just silence — which is maddening to debug).

```bash
# which class is default?
kubectl get sc
# NAME                 PROVISIONER              RECLAIMPOLICY  VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION  AGE
# standard (default)   rancher.io/local-path    Delete         WaitForFirstConsumer   false                 2d

# set a class as default
kubectl annotate sc standard \
  storageclass.kubernetes.io/is-default-class=true

# remove the default annotation from the old one if switching
kubectl annotate sc old-default \
  storageclass.kubernetes.io/is-default-class-
```

---

## kind's `standard` StorageClass

kind ships with `rancher/local-path-provisioner` registered as the `standard` StorageClass (also the default). This is what backs every `volumeClaimTemplates` PVC you create in the dojo.

```bash
kubectl get sc standard -o yaml | grep -E 'provisioner|bindingMode|reclaimPolicy|volumeExpansion'
```

Two important properties of kind's local-path:

1. **`WaitForFirstConsumer`** — the PV is not provisioned until a pod referencing the PVC is scheduled. The provisioner must know which node to create the directory on. A PVC with no pod referencing it stays `Pending` indefinitely — **this is expected, not a bug**. The moment a pod is scheduled, the PVC transitions to `Bound`.

2. **No volume expansion** — `allowVolumeExpansion: false`. If you need to resize a PVC in the dojo, you must delete the PVC and recreate it (losing data). On real cloud clusters with EBS/GCP-PD CSI drivers, expansion is supported online.

```bash
# watch a PVC go from Pending to Bound as a pod is scheduled
kubectl apply -f - <<'YAML'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: demo-pvc
  namespace: dojo-storage-demo
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: standard
  resources:
    requests:
      storage: 1Gi
YAML
kubectl get pvc demo-pvc -n dojo-storage-demo   # Pending — no pod yet
kubectl run demo-pod --image=busybox:1.36 -n dojo-storage-demo \
  --overrides='{"spec":{"volumes":[{"name":"d","persistentVolumeClaim":{"claimName":"demo-pvc"}}],"containers":[{"name":"demo-pod","image":"busybox:1.36","command":["sleep","3600"],"volumeMounts":[{"mountPath":"/data","name":"d"}]}]}}'
kubectl get pvc demo-pvc -n dojo-storage-demo   # now Bound
```

---

## Volume expansion

On StorageClasses with `allowVolumeExpansion: true` (cloud block CSI drivers), you resize a PVC by patching its request:

```bash
kubectl patch pvc data-web-0 -n dojo-stateful \
  -p '{"spec":{"resources":{"requests":{"storage":"5Gi"}}}}'

# watch the expansion condition
kubectl get pvc data-web-0 -n dojo-stateful -w
# once the CSI controller expands the block device, Conditions include FileSystemResizePending
# then the kubelet resizes the filesystem on next NodePublishVolume (pod restart or online if supported)

kubectl describe pvc data-web-0 -n dojo-stateful | grep -A5 Conditions
```

You can only expand — shrinking a PVC is not supported by any CSI driver. If you need to shrink: snapshot, delete, recreate smaller, restore.

---

## The CSI driver model

CSI (Container Storage Interface) decouples storage vendors from Kubernetes core. Every non-trivial backend ships as a CSI driver deployed alongside the cluster.

```
┌──────────────────────────── Control Plane ─────────────────────────────────┐
│                                                                              │
│  external-provisioner  ──gRPC──►  CSI Controller Plugin  (Deployment)      │
│  external-attacher     ──gRPC──►  (your storage vendor's binary)           │
│  external-resizer      ──gRPC──►                                            │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
                                          │ gRPC
┌──────────────────────────── Each Node ─────────────────────────────────────┐
│                                          ▼                                   │
│  kubelet  ◄──── volume-plugin-dir ────  CSI Node Plugin  (DaemonSet)       │
└──────────────────────────────────────────────────────────────────────────────┘
```

Three CSI operations worth knowing by name:

- **`CreateVolume`** — called by external-provisioner when a PVC binds; creates the backing block device.
- **`ControllerPublishVolume`** — attaches the block device to the node's VM (cloud providers only; not needed for local storage).
- **`NodePublishVolume`** — called by kubelet to bind-mount the device into the pod's namespace.

A `VolumeAttachment` object represents the "this PV is attached to this node" state. You rarely interact with it, but it becomes visible when a node dies ungracefully:

```bash
kubectl get volumeattachments
# NAME                                      ATTACHER              PV                   NODE     ATTACHED
# csi-abc...                                ebs.csi.aws.com       pvc-abc...           node-1   true

# a stuck detach after a dead node:
kubectl describe volumeattachment csi-abc... | grep -A5 'Message\|Reason'
# force-delete the finalizer as last resort:
kubectl patch volumeattachment csi-abc... --type=json \
  -p '[{"op":"remove","path":"/metadata/finalizers"}]'
```

---

## Debugging Storage

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| PVC stays `Pending` with no events | `WaitForFirstConsumer` + no pod referencing the PVC yet | Schedule a pod that mounts it; check `kubectl get po -A | grep <pvc-name>` |
| PVC `Pending`, Event: `no persistent volumes available for this claim and no storage class is set` | No default StorageClass exists | `kubectl get sc` — add `is-default-class=true` annotation |
| PVC `Pending`, Event: `storageclass "foo" not found` | PVC references a StorageClass that doesn't exist | Fix `storageClassName` in the PVC spec |
| PVC `Pending`, Event: `no persistent volumes available for this claim` (static provisioning) | No pre-created PV matches the PVC's access mode, capacity, and storageClassName | Create a matching PV or switch to dynamic provisioning |
| Pod `Pending`, Event: `1 node(s) had volume node affinity conflict` | PV was provisioned on node A (local-path); pod is being scheduled to node B | Delete PVC+PV; recreate; or relax pod node affinity |
| PVC stays in `Released` after PVC deletion | `reclaimPolicy: Retain` is working as intended | Remove `spec.claimRef` from the PV to move it back to `Available`, then bind a new PVC |
| Volume expansion stuck in `FileSystemResizePending` | Block device was expanded; kubelet hasn't resized the filesystem yet | Restart the pod (triggers NodePublishVolume → `resize2fs`); confirm `allowVolumeExpansion: true` on the StorageClass |

### Exact commands for each

**PVC Pending — event-driven diagnosis (always start here):**

```bash
kubectl describe pvc data-web-0 -n dojo-stateful
# scroll to Events: — provisioner writes detailed failure reasons here

# is the local-path provisioner pod healthy?
kubectl -n kube-system get pods | grep local-path
kubectl -n kube-system logs -l app=local-path-provisioner --tail=50

# what StorageClasses are available and which is default?
kubectl get sc
kubectl get sc -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}{end}'
```

**No default StorageClass:**

```bash
# identify the problem
kubectl get sc
# if no "(default)" label appears in the NAME column, there is no default

# fix it
kubectl annotate sc standard storageclass.kubernetes.io/is-default-class=true

# verify
kubectl get sc
# standard (default)   rancher.io/local-path ...
```

**Volume node affinity conflict:**

```bash
# which node does the PV require?
kubectl get pv <pv-name> \
  -o jsonpath='{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[*]}{"\n"}'

# which nodes is the pod allowed on?
kubectl describe pod web-0 -n dojo-stateful | grep -A15 'Node-Selector\|Affinity'

# if they don't overlap: delete the PVC (PV auto-deletes with policy=Delete),
# remove any conflicting node selectors, then recreate the PVC
kubectl delete pvc data-web-0 -n dojo-stateful
# the StatefulSet will recreate the PVC on next pod scheduling — provisioned on the correct node
```

> **War story.** In a multi-AZ GKE cluster, we had a StatefulSet for a single-node Elasticsearch. After a zone failover event, the pod was rescheduled to a node in a different zone — but our StorageClass was using `volumeBindingMode: Immediate`. The PV had been provisioned in `us-central1-a` the week before; the pod was now landing in `us-central1-b`. Every scheduling cycle produced: `1 node(s) had volume node affinity conflict`. The pod never started. The fix was to delete the PVC (the data was already lost from the ungraceful kill), migrate the StorageClass to `WaitForFirstConsumer`, and re-provision. The 45-minute outage was entirely caused by the wrong `volumeBindingMode`. `WaitForFirstConsumer` should be the default for any stateful workload — it guarantees the PV is created on the same node/zone that the pod actually schedules to.

---

## Checkpoint

1. Draw the full binding chain from a pod's `volumeMounts` to the physical storage, naming every API object.
2. Explain the difference between `ReadWriteOnce` and `ReadWriteOncePod` in concrete terms and give a scenario where each is the right choice.
3. Predict what happens to a PVC and its backing storage when the PVC is deleted under each of the three reclaim policies.
4. Explain why a PVC can stay `Pending` for a long time with `WaitForFirstConsumer` — and why this is correct behavior, not a bug.
5. Run the one command that tells you whether your cluster has a default StorageClass.
6. Diagnose a `volume node affinity conflict` from first principles: what two fields do you compare and where do you find them?
7. Explain what a `VolumeAttachment` object represents and name the scenario where you'd have to manually interact with one.

➡ Next up: **Running Databases on Kubernetes** — combining StatefulSets and storage in the most demanding scenario.
