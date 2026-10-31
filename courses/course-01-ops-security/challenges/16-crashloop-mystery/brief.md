# The CrashLoop Mystery

It's 2:14am. The pager fires: `api` in `dojo-crash` is serving zero traffic. You open the dashboard and every pod is cycling through the same grim status:

```
NAME                   READY   STATUS             RESTARTS       AGE
api-7c9f8b6d4f-4xk2p   0/1     CrashLoopBackOff   5 (38s ago)    3m
api-7c9f8b6d4f-pz9lt   0/1     CrashLoopBackOff   5 (41s ago)    3m
```

`CrashLoopBackOff` is not a *cause* — it's Kubernetes telling you *"your container keeps exiting, so I keep restarting it, and I'm now backing off between attempts."* The actual failure is upstream of Kubernetes, in the container. Your job is to find it with the standard method and fix the real root cause — not to paper over it by deleting the deployment.

## The method: `describe` → `logs` → `events`

Work the quartet in order. Each tool answers a different question:

| Step | Command | What it tells you |
|------|---------|-------------------|
| 1 | `kubectl -n dojo-crash describe pod <pod>` | The lifecycle: `Last State: Terminated`, the **Exit Code**, and the `Events` block at the bottom (BackOff, image pulls, OOMKilled). |
| 2 | `kubectl -n dojo-crash logs <pod> --previous` | The app's own stdout/stderr from the **crashed** instance (`--previous`), *before* the restart wiped it. This is where the real error lives. |
| 3 | `kubectl -n dojo-crash get events --sort-by=.lastTimestamp` | Cluster-level history when the pod log is empty (scheduling failures, FailedMount, image errors). |

The single most important reflex: **`logs --previous`**. A crashed container's current log is often empty (the new attempt hasn't printed yet, or already died), so the live `logs` lies to you. `--previous` reads the dead container's log and almost always names the problem outright.

> **War story.** A team once spent 40 minutes convinced a CrashLoop was an image problem because `kubectl logs` returned nothing. The container was exiting so fast the *current* attempt had no output yet. The instant someone added `--previous`, the log read `panic: required env MONGO_URI unset`. The fix took nine seconds; the diagnosis took 40 minutes — all for want of one flag. **When logs look empty on a crashing pod, you are reading the wrong instance.**

## Reading the exit code

`describe` shows a `Last State: Terminated` with an **Exit Code**. Learn the common ones:

| Exit code | Usual meaning |
|-----------|---------------|
| `1` | Generic application error — the app chose to die (bad config, failed precondition). Read the log. |
| `137` | `128 + 9` = SIGKILL. Almost always **OOMKilled** (check `describe` for `Reason: OOMKilled`) or a failed liveness probe killing the container. |
| `139` | `128 + 11` = SIGSEGV — a native crash. |
| `127` | "command not found" — a bad `command`/`args` or missing binary in the image. |
| `0` | Exited *successfully* but Kubernetes still restarted it — a job-shaped process in a Deployment (wrong workload kind). |

## Mission

Diagnose `api` in `dojo-crash`, fix the underlying cause, and bring the Deployment to a healthy steady state. The verifier accepts your work only when **all** of these are true for Deployment `api`:

1. **`readyReplicas ≥ 1`** — at least one pod is actually Ready and serving.
2. **Every `app=api` pod is `Running`** — none is `Pending`, `Error`, or `CrashLoopBackOff`.
3. **Zero restarts on the running pods** — the fix must produce *fresh, stable* pods (restart count `0`), not a pod that happens to be briefly up between crashes.

## Rules of engagement

- Work in namespace `dojo-crash` (the setup script creates it).
- Fix the **root cause**. Scaling to zero, deleting the Deployment, or swapping the image for something that ignores the problem are not fixes — the verifier inspects the live `api` Deployment.
- You may fix it imperatively (`kubectl set env`, `kubectl edit`) or by editing YAML and `kubectl apply`-ing it. The verifier only inspects final state.

When you believe the pods are healthy, run the verifier. It prints the flag only once the Deployment is genuinely stable.
