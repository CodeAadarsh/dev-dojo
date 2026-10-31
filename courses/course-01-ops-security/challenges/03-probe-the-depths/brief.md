# Probe the Depths

A service in `dojo-probes` has **no health checks at all**. On paper it's "up" — the pods are `Running`, the Deployment reports its replicas available. But `Running` only means the container process hasn't exited. It says nothing about whether the app can actually serve a request, and it gives Kubernetes no way to recover a process that has wedged itself into a bad state.

Two different probes fix two different problems, and conflating them is one of the most common ways people turn a healthy service into a `CrashLoopBackOff`.

| Probe | Question it answers | What Kubernetes does on failure |
|-------|---------------------|---------------------------------|
| `readinessProbe` | "Can this pod take traffic *right now*?" | Removes the pod from Service endpoints — **no restart**. Traffic routes elsewhere. |
| `livenessProbe` | "Is this process wedged and unrecoverable?" | **Kills and restarts** the container. |

> **The failure mode that bites everyone:** a `livenessProbe` that's too aggressive — short `initialDelaySeconds`, a path that isn't ready during startup, or a timeout tighter than a real GC pause — will keep *killing a perfectly healthy container* before it finishes starting. The result is an endless `CrashLoopBackOff` caused entirely by the health check, not the app. Readiness gates traffic; liveness restarts. Get the two confused and you either route to dead pods (missing readiness) or murder live ones (trigger-happy liveness).

## Mission

Add **both** a `readinessProbe` and a `livenessProbe` to `container[0]` of the `web` Deployment in namespace `dojo-probes`. The image is `nginx:1.27-alpine`, which serves on port 80 — use an `httpGet` probe against path `/` on port `80` for both. Keep the pods healthy: a liveness probe tuned too tight will crashloop the Deployment and the verifier will see fewer Ready replicas than desired.

## Target state

The verifier accepts your work only when **all** of these are true for Deployment `web` in `dojo-probes`:

1. The Deployment exists.
2. `container[0]` has a non-empty **`readinessProbe`**.
3. `container[0]` has a non-empty **`livenessProbe`**.
4. `status.readyReplicas` is **≥** `spec.replicas` — i.e. every desired pod is Ready, proving your liveness probe didn't start a crashloop.

When you believe the cluster is in the target state, run the verifier. It inspects live cluster state and prints the flag only if every check passes.
