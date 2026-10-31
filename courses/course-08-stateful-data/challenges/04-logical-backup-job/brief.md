# Logical Backup Job

Your platform team just filed a ticket: *"Before the Saturday maintenance window we need a verified backup of the user-records service. The backup must land on persistent storage — not ephemeral container scratch space — so it survives pod restarts and can be streamed off-cluster."*

The source data is already there as a ConfigMap called `app-data` in namespace `dojo-backup`. Your job is to automate the export.

## Why Jobs (not CronJobs, not Deployments) for backup

A Kubernetes `Job` tracks completion: it runs one or more pods to successful exit and then holds the result in `status.succeeded`. That property is what makes it auditable — you can prove a backup ran and finished without tailing logs. A Deployment would restart forever; a CronJob is right for recurring backups but adds scheduling complexity you don't need for a one-shot export.

The other half is storage. An emptyDir or ConfigMap-backed volume lives and dies with the pod. To persist a backup artifact you need a `PersistentVolumeClaim` — a volume with a lifecycle independent of any pod.

## Target state

The verifier will accept your work only when **both** of these are true in namespace `dojo-backup`:

1. **A Job whose `status.succeeded >= 1`** — at least one pod completed exit-0, meaning the backup actually ran to completion.
2. **A PersistentVolumeClaim in phase `Bound`** — a persistent volume was provisioned and is ready; the backup data has durable storage.

The Job must write *something* to the PVC. The verifier does not inspect the artifact content — it proves the plumbing works: Job succeeded and PVC is Bound.

## Rules of engagement

- Work exclusively in namespace `dojo-backup` (the setup script creates it).
- The source data is in ConfigMap `app-data` — mount it and copy the contents to the PVC in your Job.
- Name your PVC `backup-store` (any `storageClassName` accepted — the `standard` provisioner in kind works fine).
- The Job image must be something that can write a file: `busybox:1.36` or `alpine:3.19` are fine.
- Do **not** use `hostPath` volumes — the backup must live on a real PVC.

When the Job has completed and the PVC is Bound, run the verifier.
