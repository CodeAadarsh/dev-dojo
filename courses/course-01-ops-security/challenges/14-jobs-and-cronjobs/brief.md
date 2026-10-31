# Batch It

Not everything is a long-running server. A nightly DB backup, a one-off schema migration, a report that aggregates yesterday's events, a cache warm-up — these **start, do work, and finish**. Model them as a Deployment and you get a container that "completes," gets marked as a crash, and is restarted forever. That's the classic `CrashLoopBackOff`-that-isn't-a-crash incident.

Kubernetes has first-class batch primitives for exactly this: **Job** (run N pods to successful completion) and **CronJob** (create a Job on a schedule).

## Deployment vs Job vs CronJob — pick the right shape

| Workload | Controller | Restart semantics | "Done" means |
|----------|-----------|-------------------|--------------|
| Web server, API | Deployment | restart forever (`Always`) | never — it's a service |
| Migration, backup, import | **Job** | retry until success (`OnFailure`/`Never`) | pod exits 0 |
| Nightly backup, hourly report | **CronJob** | spawns a Job per tick | each tick's Job completes |

```
CronJob  ──(every schedule tick)──▶  Job  ──(spawns)──▶  Pod ──▶ exit 0 ✓
   "*/1 * * * *"                  succeeded: 1        completions met
```

A Job's whole identity is **terminal success**: it tracks `.status.succeeded`, honours `backoffLimit` for retries, and (unlike a Deployment) a pod exiting `0` is the goal, not a failure.

## Mission

The setup script created an **empty** namespace `dojo-batch`. You will create two objects in it:

1. **A Job** that runs a short task to completion — e.g. `busybox:1.36` printing a line and exiting `0`. It must reach `status.succeeded >= 1`.
2. **A CronJob** with a valid schedule — run it **every minute** (`"*/1 * * * *"`).

## Target state — exactly what the verifier checks

In namespace `dojo-batch`:

1. At least one **Job** exists whose `.status.succeeded` is **>= 1** (the pod ran and exited 0 — the verifier waits for nothing, so give your Job a second or two to finish before running it).
2. At least one **CronJob** exists with a non-empty, **valid** `.spec.schedule` — either a standard 5-field cron expression (`"*/1 * * * *"`) or a macro (`@hourly`).

Run the verifier once both are satisfied; it prints the flag only if every check passes.

> **Why the Job must actually *succeed*, not just exist:** a Job that is created but whose pod is `Error`/`Pending` has `succeeded: 0`. The verifier reads real status, so a typo'd command that exits non-zero will fail the check even though `kubectl get job` shows the object. "It exists" and "it worked" are different facts — the batch world lives entirely in the second one.
