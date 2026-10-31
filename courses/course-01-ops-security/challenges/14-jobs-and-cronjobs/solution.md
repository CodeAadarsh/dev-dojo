# Solution — Batch It

Two tiny objects. The lessons are in the fields people skip.

## The Job

```yaml
# job.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: hello-batch
  namespace: dojo-batch
spec:
  completions: 1          # how many successful pods = done
  parallelism: 1          # how many run at once
  backoffLimit: 4         # retries before the Job is marked Failed
  ttlSecondsAfterFinished: 600   # auto-garbage-collect 10 min after finishing
  template:
    spec:
      restartPolicy: Never         # Job pods MUST be Never or OnFailure (not Always)
      containers:
        - name: work
          image: busybox:1.36
          command: ["sh", "-c", "echo processing batch...; sleep 2; echo done; exit 0"]
```

```bash
kubectl apply -f job.yaml
kubectl -n dojo-batch wait --for=condition=complete job/hello-batch --timeout=60s
kubectl -n dojo-batch get job hello-batch        # COMPLETIONS should read 1/1
```

The imperative one-liner if you don't want YAML:

```bash
kubectl -n dojo-batch create job hello-batch \
  --image=busybox:1.36 -- sh -c 'echo processing batch...; sleep 2; echo done'
```

## The CronJob

```yaml
# cronjob.yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: every-minute
  namespace: dojo-batch
spec:
  schedule: "*/1 * * * *"          # min hour day-of-month month day-of-week
  concurrencyPolicy: Forbid        # don't start a new run if the last is still going
  startingDeadlineSeconds: 30      # skip a tick rather than pile up if controller was down
  successfulJobsHistoryLimit: 3    # keep the last 3 succeeded Jobs
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      backoffLimit: 2
      template:
        spec:
          restartPolicy: OnFailure
          containers:
            - name: tick
              image: busybox:1.36
              command: ["sh", "-c", "date; echo cron tick"]
```

```bash
kubectl apply -f cronjob.yaml
kubectl -n dojo-batch get cronjob every-minute          # SCHEDULE shows */1 * * * *
bash courses/course-01-ops-security/challenges/14-jobs-and-cronjobs/verify.sh
```

Imperative equivalent:

```bash
kubectl -n dojo-batch create cronjob every-minute \
  --image=busybox:1.36 --schedule="*/1 * * * *" -- sh -c 'date; echo cron tick'
```

## Why each field matters

- **`restartPolicy: Never` / `OnFailure`** — a Job pod with `Always` is rejected by the API server. `Always` means "a clean exit is a reason to restart," which is the opposite of batch semantics. `OnFailure` restarts the *same* pod on non-zero exit; `Never` spins a *new* pod per attempt (better when you want each attempt's logs preserved).
- **`backoffLimit`** — how many failed attempts before the Job itself is declared `Failed`. Retries are exponentially backed off (10s, 20s, 40s…, capped at 6 min). Set it deliberately: a migration you want to retry twice is `backoffLimit: 2`, not the default 6.
- **`completions` / `parallelism`** — `completions: 10, parallelism: 3` gives you a work-queue style fan-out: 10 successful pods total, at most 3 running at once.
- **`ttlSecondsAfterFinished`** — without it, finished Jobs (and their pods) linger forever and clutter the namespace. The TTL controller cleans them up automatically. Easy to forget, annoying to discover.
- **`concurrencyPolicy: Forbid`** — the single most important CronJob field. The default `Allow` lets runs overlap, so a backup that takes 90 seconds on a `*/1` schedule will stack runs on top of each other until the node falls over. `Forbid` skips a tick if the previous Job is still running; `Replace` kills the old one and starts fresh.

## Debugging batch workloads

| Symptom | Likely cause | Diagnose | Fix |
|---------|--------------|----------|-----|
| Job stuck, `COMPLETIONS 0/1` | pod exits non-zero; retrying under backoff | `kubectl -n dojo-batch get pods` then `kubectl logs <pod>` | fix the command / exit code |
| `Job ... spec.template.spec.restartPolicy: Unsupported value: "Always"` | copied a Deployment template | read the apply error | set `restartPolicy: Never` or `OnFailure` |
| CronJob exists but never fires | invalid schedule, or `startingDeadlineSeconds` too small after a controller outage | `kubectl -n dojo-batch describe cronjob <name>` → Events | fix the cron expression; widen the deadline |
| Namespace filling with Completed pods | no `ttlSecondsAfterFinished`, high history limits | `kubectl -n dojo-batch get pods` | add TTL; lower `successfulJobsHistoryLimit` |
| Two CronJob runs clobbering shared state | `concurrencyPolicy: Allow` (default) and runtime > interval | `kubectl -n dojo-batch get jobs` shows overlapping active | set `concurrencyPolicy: Forbid` |

Fast triage commands:

```bash
kubectl -n dojo-batch get job,cronjob,pods
kubectl -n dojo-batch describe job/hello-batch | sed -n '/Events/,$p'
kubectl -n dojo-batch logs job/hello-batch           # logs from the Job's pod(s)
kubectl -n dojo-batch get cronjob every-minute -o jsonpath='{.status.lastScheduleTime}'; echo
```

> **War story.** A nightly `pg_dump` CronJob on a busy database started taking 70 minutes as the dataset grew — but it was scheduled `*/60` with the default `concurrencyPolicy: Allow`. Each run overlapped the previous one, two then three `pg_dump` processes hammered the same primary, replication lag blew past the alert threshold, and the on-call got paged for a "database outage" that was really self-inflicted by overlapping backups. One line fixed it for good: `concurrencyPolicy: Forbid`. The dump that's still running simply skips the next tick instead of racing itself.

## Hardening preview

Batch pods are a favourite for **privilege creep** — "it's just a migration, give it cluster-admin." Treat them like any other workload: a dedicated ServiceAccount with least-privilege RBAC, `automountServiceAccountToken: false` when the Job never calls the API, resource `requests`/`limits` so a runaway import can't starve the node, and a `securityContext` with `runAsNonRoot: true`. A CronJob that runs forever with a stale, over-scoped token is a standing credential an attacker loves.
