# Solution — State That Survives

Delete the Deployment and replace it with a StatefulSet that has a `volumeClaimTemplate`. A StatefulSet also wants a **headless Service** (`clusterIP: None`) to back its stable per-pod DNS.

```yaml
# notes-sts.yaml
apiVersion: v1
kind: Service
metadata:
  name: notes           # headless service: gives pods stable DNS (notes-0.notes...)
  namespace: dojo-storage
  labels:
    app: notes
spec:
  clusterIP: None
  selector:
    app: notes
  ports:
    - port: 80
      name: http
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: notes
  namespace: dojo-storage
spec:
  serviceName: notes      # must match the headless Service above
  replicas: 1
  selector:
    matchLabels:
      app: notes
  template:
    metadata:
      labels:
        app: notes
    spec:
      containers:
        - name: notes
          image: busybox:1.36
          command:
            - sh
            - -c
            - 'echo "$(date -u) booted on $(hostname)" >> /data/notes.log; echo "=== /data/notes.log ==="; cat /data/notes.log; sleep 3600'
          volumeMounts:
            - name: data           # <-- matches the volumeClaimTemplate name
              mountPath: /data
  volumeClaimTemplates:
    - metadata:
        name: data                 # produces PVC data-notes-0, data-notes-1, ...
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: standard # kind's default dynamic provisioner
        resources:
          requests:
            storage: 1Gi
```

Apply — removing the old Deployment first so the label selector isn't owned by two controllers:

```bash
kubectl -n dojo-storage delete deployment notes
kubectl apply -f notes-sts.yaml
kubectl -n dojo-storage rollout status statefulset/notes
bash courses/course-01-ops-security/challenges/12-stateful-storage/verify.sh
```

## Why each piece is exactly this

- **`volumeClaimTemplates` (not `volumes`)** is the switch. The StatefulSet controller stamps out one PVC per replica — `data-notes-0` for `notes-0` — and **re-binds the same PVC to the same ordinal** on restart/reschedule. That's how the data follows the pod.
- **`storageClassName: standard`** uses kind's built-in `rancher.io/local-path` provisioner, which dynamically creates a PV on demand. On a real cluster this would be your cloud's block storage (EBS gp3, PD, Azure Disk). No manually pre-created PV needed.
- **`ReadWriteOnce`** is correct here: each PVC is owned by exactly one pod. (This is also *why* a shared PVC on a Deployment fails to scale — RWO binds to one node.)
- **Headless Service + `serviceName`** gives each pod stable DNS (`notes-0.notes.dojo-storage.svc`). Not strictly required for the verifier, but it's half the point of a StatefulSet and you should ship it.
- **Delete the old Deployment first.** Leaving it running means two controllers fight over `app=notes` pods.

## Prove it survives now

```bash
kubectl -n dojo-storage exec notes-0 -- sh -c 'echo "line A" >> /data/notes.log'
kubectl -n dojo-storage delete pod notes-0            # pod is recreated, SAME PVC re-attached
kubectl -n dojo-storage exec notes-0 -- cat /data/notes.log   # "line A" is STILL THERE
```

That's the entire lesson: the pod is cattle, the PVC is the pet.

## Debugging StatefulSet storage

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Pod stuck `Pending`, PVC stuck `Pending` | No default StorageClass, or a name typo | `kubectl get sc` — on kind it's `standard` (marked default). Set `storageClassName` to it. |
| Pod `ContainerCreating` forever | Volume can't attach / provisioner not running | `kubectl -n dojo-storage describe pod notes-0` → read the Events; check `kubectl -n local-path-storage get pods`. |
| `readyReplicas` is 0 but pod is Running | No readiness probe, or app not actually ready | `kubectl -n dojo-storage get pod notes-0 -o wide`; add/inspect the readinessProbe. |
| PVC won't delete after you remove the STS | StatefulSet PVCs are **retained by design** | Delete them explicitly: `kubectl -n dojo-storage delete pvc -l app=notes`. |
| Data gone after scaling down then up | You deleted the PVC in between | Keep the PVC; scaling the STS back up re-attaches the retained `data-notes-N`. |

Diagnostic commands:

```bash
kubectl -n dojo-storage get statefulset,pod,pvc,pv
kubectl get storageclass                                  # which SC is (default)?
kubectl -n dojo-storage describe pvc data-notes-0         # Events show binding/provisioning
kubectl -n dojo-storage describe pod notes-0              # Events show attach failures
kubectl -n local-path-storage get pods                    # kind's provisioner health
```

> **War story.** An analytics team ran their primary Postgres as a single-replica **Deployment** with a `ReadWriteOnce` PVC "because it was simpler than a StatefulSet." It worked for months — until a routine `kubectl set image` triggered a rolling update. The rollout created the *new* pod before the *old* one released the RWO volume; the new pod wedged in `ContainerCreating` waiting for a volume it could never attach, while the old pod had already been told to terminate. Thirty-five minutes of downtime on the primary datastore during business hours. A StatefulSet with `volumeClaimTemplates` and `OrderedReady` pod management would have serialized this correctly — old pod fully gone, volume detached, then the new pod attaches. The takeaway: **RWO storage and the Deployment rollout model are fundamentally incompatible; stateful workloads belong in StatefulSets.**

## Hardening / production preview

- Set `persistentVolumeClaimRetentionPolicy` (K8s 1.27+) to control whether PVCs are deleted on scale-down/delete — the default retains them, which is safe but can leak storage.
- Back real data with a replicated storage class and take volume snapshots (`VolumeSnapshot`) — a PVC surviving a pod restart is **not** a backup.
- For databases, prefer a purpose-built operator (CloudNativePG, Zalando Postgres) over hand-rolled StatefulSets; they handle failover, backups, and PVC lifecycle.

## Checkpoint

You've got this when you can:

1. State in one sentence why `emptyDir` loses data and `volumeClaimTemplates` doesn't.
2. Explain why a `ReadWriteOnce` PVC on a Deployment deadlocks a rollout.
3. Name what a StatefulSet adds over a Deployment: stable identity, stable per-pod storage, ordered lifecycle.
4. Predict the PVC name a `volumeClaimTemplate` named `data` produces for replica 0 (`data-notes-0`).
5. Recall that StatefulSet PVCs are retained on delete and must be cleaned up explicitly.
