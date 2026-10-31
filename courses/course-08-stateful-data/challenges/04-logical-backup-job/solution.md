# Solution — Logical Backup Job

Two manifests: a PVC for durable storage, and a Job that mounts both the source ConfigMap and the PVC, then copies the data.

```yaml
# backup-pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: backup-store
  namespace: dojo-backup
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 100Mi
  storageClassName: standard      # kind's default provisioner
---
# backup-job.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: logical-backup
  namespace: dojo-backup
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: backup
          image: busybox:1.36
          command:
            - sh
            - -c
            - |
              mkdir -p /backup
              cp /source/records.json /backup/records.json
              cp /source/schema.sql   /backup/schema.sql
              echo "backup completed at $(date -u)" > /backup/manifest.txt
              echo "Backup written to /backup:"
              ls -lh /backup
          volumeMounts:
            - name: source-data
              mountPath: /source
              readOnly: true
            - name: backup-store
              mountPath: /backup
      volumes:
        - name: source-data
          configMap:
            name: app-data
        - name: backup-store
          persistentVolumeClaim:
            claimName: backup-store
  backoffLimit: 2
```

Apply and verify:

```bash
kubectl apply -f backup-pvc.yaml -f backup-job.yaml
kubectl -n dojo-backup get job logical-backup -w
# wait for COMPLETIONS 1/1
bash courses/course-08-stateful-data/challenges/04-logical-backup-job/verify.sh
```

## Why each piece matters

**`restartPolicy: Never` vs `OnFailure`.** A Job pod should be `Never` or `OnFailure`, never `Always` (that's for Deployments). `Never` creates a new pod per retry (useful for debugging — you can `kubectl logs` each failed attempt). `OnFailure` restarts the same pod, which means you lose logs from the previous attempt. For backup jobs that can leave partial output, `Never` with a low `backoffLimit` is safer.

**ConfigMap as a volume, not env vars.** The source data is multi-key and multi-line — mounting it as a volume (one file per key) is idiomatic. Each key in `.data` becomes a file at the `mountPath`. `env:` and `envFrom:` are for scalar config, not file payloads.

**PVC lifecycle vs pod lifecycle.** Once the Job completes, the pods are gone but the PVC and its bound PV survive. In a real DR scenario you'd stream the backup off-cluster at this point (`kubectl cp`, a sidecar streaming to object storage, or Velero). The Retain reclaim policy (next challenge) is what prevents the PV from being garbage-collected if the PVC is deleted.

**`backoffLimit: 2`.** The default is 6. For a backup job, 6 retries with `restartPolicy: Never` means 6 pod shells left behind on failure, all using cluster resources. Set it low and fix the root cause instead of retrying.

## Attacker's view

A Job with read access to a ConfigMap that holds database credentials (a common pattern) is a data-exfiltration primitive. From the cluster attacker's perspective, all they need is a `pods/create` permission in the right namespace — they mount any Secret or ConfigMap they have `get` rights on and copy it out. This is why RBAC on `pods/create` deserves the same scrutiny as RBAC on `secrets/get`.
