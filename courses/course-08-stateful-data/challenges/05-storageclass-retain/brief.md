# StorageClass: Retain Your Data

A postmortem lands in your inbox: *"A junior engineer deleted the PVC to 'clean up' before re-deploying the database. The cloud provisioner reclaimed the volume immediately. 48 hours of data, gone."*

The root cause was a StorageClass with `reclaimPolicy: Delete` — the cluster default. When the PVC was deleted, the underlying PV and its disk were automatically destroyed. The fix is a StorageClass with `reclaimPolicy: Retain`, which keeps the PV around even after the PVC is gone, leaving the data accessible for manual recovery.

The second requirement is `allowVolumeExpansion: true`. Without it, the only way to give a StatefulSet more disk space is to delete and recreate the PVC — which, depending on your app, means downtime and a restore. With expansion enabled you edit the PVC's `spec.resources.requests.storage` and the provisioner resizes the disk live (on cloud providers that support it; in kind it's a no-op but the API accepts the request).

## Target state

The verifier accepts your work when **all three** are true:

1. **A StorageClass with `reclaimPolicy: Retain`** exists in the cluster.
2. **That same StorageClass has `allowVolumeExpansion: true`**.
3. **A PVC in namespace `dojo-sc` references that StorageClass by name** and is in phase `Bound`.

The standard `standard` StorageClass in kind has `reclaimPolicy: Delete` — you must create a new one.

## Rules of engagement

- Work in namespace `dojo-sc` (the setup script creates it).
- Any StorageClass name is fine. The verifier navigates from the PVC back to the StorageClass by name, so they must match.
- Use `provisioner: rancher.io/local-path` (kind's built-in dynamic provisioner) or `provisioner: docker.io/hostpath` — both work in the dojo cluster without extra installs.
- Alternatively, use `provisioner: kubernetes.io/no-provisioner` with a manually-created PV if you want to explore static provisioning; just make sure the PVC binds.

When the PVC is Bound, run the verifier.
