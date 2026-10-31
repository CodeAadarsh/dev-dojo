# Page at 3am

Your phone lights up:

> **[FIRING] SLOBurn — web-tier availability**
> error budget burning at 14x · success rate 0% · page

You roll over, open the laptop, and the first three things you check all look *fine*:

```
$ kubectl -n dojo-incident get deploy web
NAME   READY   UP-TO-DATE   AVAILABLE   AGE
web    0/3     3            0           6m

$ kubectl -n dojo-incident get pods -l app=web
NAME                   READY   STATUS    RESTARTS   AGE
web-7d9c...-2xk9       0/1     Running   0          6m
web-7d9c...-lm4p       0/1     Running   0          6m
web-7d9c...-qg7t       0/1     Running   0          6m

$ kubectl -n dojo-incident logs deploy/web
<nginx access/error log — clean, nothing alarming>
```

The container isn't crashing. There's no `CrashLoopBackOff`, no `ImagePullBackOff`, no OOMKill, exit code nothing. The logs are *clean*. And yet `AVAILABLE` is `0`, the `READY` column says `0/1` on every pod, and every request to the service returns nothing. This is the incident that separates people who read Kubernetes state from people who guess: **the deploy is green, the app is healthy, and the service is still completely dark.**

This is a **debugging drill.** The setup script has planted a `web` Deployment in namespace `dojo-incident` that is broken in one specific, extremely common, production-realistic way. Your job is to find it using the triage method below — not to be told the answer — and fix it so the service actually serves.

## The triage method (learn this ladder, not this one bug)

When a service is down, walk the request path from the outside in and let Kubernetes tell you where it breaks. Cheapest signal first.

| Step | Command | What it tells you |
|------|---------|-------------------|
| 1. Deployment status | `kubectl -n dojo-incident get deploy web` | `READY`/`AVAILABLE` < desired → pods exist but aren't *Ready* |
| 2. Pod status | `kubectl -n dojo-incident get pods -l app=web` | `STATUS=Running` but `READY=0/1` → the container runs but fails its **readiness** gate |
| 3. Pod detail | `kubectl -n dojo-incident describe pod <pod>` | the `Events:` and `Conditions:` at the bottom name the failing probe and *why* |
| 4. App logs | `kubectl -n dojo-incident logs <pod>` | clean logs + failing readiness = the app is fine, the **probe config** disagrees with reality |
| 5. Service wiring | `kubectl -n dojo-incident get endpoints web` | **empty** endpoints = the Service has zero backends → every request 503s |
| 6. Cluster events | `kubectl -n dojo-incident get events --sort-by=.lastTimestamp` | timeline of probe failures / endpoint churn |

The tell in this incident is the gap between two facts: **the container is Running and its logs are clean, but every pod is `0/1` Ready and the Service's `endpoints` list is empty.** A pod only joins a Service's endpoints when it is *Ready*; a pod is only Ready when its `readinessProbe` passes. So the question collapses to: **why is a healthy container failing its readiness probe?** `describe pod` quotes the exact probe failure — read it literally, then compare what the probe is checking against what the container actually does.

> **Think in terms of "what makes a pod Ready."** A `Running` phase means the container process started. `Ready` means the kubelet's readiness probe succeeded. Those are different claims, and the endpoint controller only cares about the second one. An incident where `Running != Ready` is almost always a probe that disagrees with the app — wrong port, wrong path, wrong scheme, or a timeout too tight for a slow starter.

## Mission

Diagnose why the `web` Deployment in `dojo-incident` has pods that run but never become Ready, fix the root cause, and get the service healthy.

The verifier will accept your work only when **all** of these are true in `dojo-incident`:

1. **`readyReplicas >= spec.replicas`** for Deployment `web` — every desired pod is actually Ready, not just Running.
2. **Every `web` pod is in phase `Running`** (you didn't "fix" it by scaling to zero or deleting the workload).
3. **The `web` Service has at least one endpoint** — there are real backends behind the service IP again.

## Rules of engagement

- Work in namespace `dojo-incident` (the setup script creates it, the Deployment, and the `web` Service).
- Fix the **root cause** in the Deployment spec — don't paper over it by deleting the probe entirely or by editing the Service to dodge the problem. (The verifier requires a healthy, Ready-gated Deployment, so a bare removal that leaves pods unready won't pass anyway.)
- `kubectl edit deploy web` or `kubectl apply` of a corrected manifest both work — the verifier only inspects final state.

When the service is healthy again, run the verifier (section 3 above). It inspects your live cluster and prints the flag only if every check passes.
