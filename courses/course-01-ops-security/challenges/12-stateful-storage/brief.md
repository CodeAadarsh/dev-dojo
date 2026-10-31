# State That Survives

Postmortem excerpt: *"At 14:02 a node was cordoned for a kernel patch. The `notes` pod rescheduled onto another node and came up healthy in 8 seconds. We lost every note written since the last pod start. RCA: the volume was an `emptyDir`."*

`emptyDir` is a scratch disk tied to the **pod's lifetime on a node**. Pod dies, is evicted, or reschedules — the directory is gone. It's perfect for a cache or a scratch space between init and main containers, and catastrophic for anything you expected to keep.

```
  emptyDir (Deployment)                        volumeClaimTemplate (StatefulSet)
  ┌─────────────┐                              ┌─────────────┐        ┌──────────────────┐
  │ pod notes-x │                              │ pod notes-0 │──bind─▶ │ PVC data-notes-0 │
  │  /data ─────┼─▶ node scratch disk          │  /data ─────┼─▶      │   ↓ bound        │
  └─────────────┘     (dies with the pod)      └─────────────┘        │ PV (StorageClass │
        │ reschedule / restart                       │ reschedule     │     standard)    │
        ▼                                            ▼                └──────────────────┘
  ┌─────────────┐  ← /data is EMPTY again      ┌─────────────┐             ▲ same PVC
  │ pod notes-y │                              │ pod notes-0 │─────────────┘ re-attached
  └─────────────┘                              └─────────────┘  ← /data still has the data
```

The fix is a **StatefulSet** with a **`volumeClaimTemplate`**. The StatefulSet gives each replica a *stable identity* (`notes-0`, `notes-1`, …); the volumeClaimTemplate provisions a **PersistentVolumeClaim per replica** (`data-notes-0`) that is **re-attached to that same identity** across restarts and reschedules. The PVC binds to a PersistentVolume backed by a StorageClass — kind ships one named `standard` with a dynamic provisioner, so you don't pre-create any PV.

## Why not just add a PVC to the Deployment?

You can mount a PVC in a Deployment, but it breaks the moment you scale or roll:

| Approach | What goes wrong |
|----------|-----------------|
| Deployment + one shared PVC (`ReadWriteOnce`) | All replicas want the same volume; RWO binds to one node, so extra replicas get stuck `Pending`/`ContainerCreating`. |
| Deployment rollout with RWO PVC | New pod can't attach the volume until the old pod fully detaches → rollout can deadlock. |
| Deployment, any PVC | No per-replica identity — pod `notes-abc123` has no stable claim; you can't reason about *which* pod owns *which* data. |

`volumeClaimTemplates` exists precisely to solve this: one claim per stable pod identity, created and re-bound automatically.

## Mission

In namespace `dojo-storage`, replace the `notes` **Deployment** (which uses `emptyDir`) with a **StatefulSet** that uses `volumeClaimTemplates`, so `/data` survives a pod delete/reschedule.

The verifier inspects live state and prints the flag when **all** of these hold:

1. A **StatefulSet** exists in `dojo-storage` whose spec defines **`volumeClaimTemplates`** (an emptyDir StatefulSet does not count).
2. At least one **PersistentVolumeClaim** in the namespace is in phase **`Bound`** (the template provisions one per replica against StorageClass `standard`).
3. The StatefulSet reports **`readyReplicas >= 1`** — the pod is actually Running with its volume attached.

## Prove the problem first (optional but worth it)

```bash
kubectl -n dojo-storage exec deploy/notes -- cat /data/notes.log   # has one boot line
kubectl -n dojo-storage delete pod -l app=notes                    # force a restart
kubectl -n dojo-storage exec deploy/notes -- cat /data/notes.log   # history GONE — fresh file
```

That data loss is the whole reason StatefulSets exist. Fix it, then run the verifier.
