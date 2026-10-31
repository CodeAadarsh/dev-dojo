# Drain Gracefully

Your `web` service passes every health check, survives node drains, autoscales — and *still* throws a spike of 502s and connection resets every single deploy. The dashboards are maddening: error rate jumps for 3–5 seconds exactly when a rollout or scale-down happens, then settles. QA can't reproduce it by hand. It only shows up under live traffic.

This is the single most common "invisible" reliability bug in Kubernetes, and it is **not** a bug in your app. It's a race between two things that happen *in parallel* when a pod is told to go away.

## What actually happens on `kubectl delete pod` (or a rollout, or a scale-down)

When a pod is terminated, the control plane fires **two independent sequences at the same moment**:

```
   t=0  pod marked Terminating
        │
        ├─► (A) kubelet sends SIGTERM to your container ─────────► app starts exiting NOW
        │
        └─► (B) pod removed from Endpoints ─► kube-proxy / ingress ─► nodes update iptables/ipvs
                 (this is eventually-consistent and takes 100s of ms to seconds)
```

Nothing synchronizes (A) with (B). So your app receives SIGTERM and begins shutting down **while kube-proxy on some node still has a stale rule pointing traffic at it**. Those in-flight requests hit a socket that's already closing — RST, 502, "upstream connection reset". The fix is to make the container **stall its own SIGTERM** until the endpoint removal has had time to propagate everywhere.

That stall is a `preStop` hook. The classic one is a plain sleep:

```
   t=0  pod Terminating ─► preStop: sleep 15 runs FIRST ─────────────┐
                           (endpoint removal propagates during this)  │
   t=15 preStop returns ─► NOW kubelet sends SIGTERM ─► app exits     ▼  clean: no new traffic was routed here
```

`preStop` runs **to completion before** SIGTERM is sent. During the sleep, the pod is already out of rotation, kube-proxy catches up, and by the time your app is actually asked to stop, nothing is being sent to it anymore.

Two things make that hook useless if you get them wrong:

- **`terminationGracePeriodSeconds` must be at least as long as the preStop sleep.** The grace period is the *total* budget for `preStop` **plus** SIGTERM handling. If `preStop` sleeps 30s but the grace period is 30s, the kubelet SIGKILLs the container the instant the sleep ends — your app never gets a clean SIGTERM. The grace period has to cover the sleep **and** leave headroom for the app to finish in-flight work.
- **No `readinessProbe` means the pod was never cleanly in rotation to begin with** — and a readiness probe is also what lets the endpoint controller take the pod *out* of rotation promptly. A service with no readiness signal routes to pods that aren't ready to serve, which is the same class of bug from the other direction.

## Mission

Make the `web` Deployment in namespace `dojo-grace` drain cleanly on termination.

The verifier will accept your work only when **all** of these are true for Deployment `web` in `dojo-grace`:

1. **A container `lifecycle.preStop` hook** is defined — a sleep long enough to let endpoint removal propagate (the brief suggests `sleep 15`).
2. **`terminationGracePeriodSeconds` is set and is `>=` the preStop sleep** — so the kubelet doesn't SIGKILL the container mid-sleep. (The preStop sleep itself must be a meaningful `>= 5` seconds — a 1-second sleep doesn't drain anything.)
3. **A `readinessProbe`** is present on the container.
4. **`readyReplicas >= 1`** — at least one pod actually made it to Ready with your new spec, i.e. the probe passes and the pods rolled out.

## Rules of engagement

- Work in namespace `dojo-grace` (the setup script creates it and plants the broken `web` Deployment).
- You may `kubectl edit` the live Deployment or write YAML and `kubectl apply` it — the verifier only inspects final state.
- The image is `nginx:1.27-alpine`, serving on port 80. Use `/` as the readiness path and an `exec` preStop like `["/bin/sh","-c","sleep 15"]`.
- Keep `terminationGracePeriodSeconds` comfortably above your sleep (e.g. sleep `15`, grace `30`) so there's room for SIGTERM handling after the drain.

When the Deployment is in the target state, run the verifier (section 3 above). It inspects your live cluster and prints the flag only if every check passes.
