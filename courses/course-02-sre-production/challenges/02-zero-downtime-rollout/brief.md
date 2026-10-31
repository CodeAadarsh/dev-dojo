# Zero-Downtime Rollout

A product manager files the same bug every sprint: *"Users get a handful of 502s every time we deploy."* The service has three replicas and plenty of headroom, so nobody believes it's a capacity problem — but the dashboard doesn't lie. There's a sawtooth of errors that lines up exactly with each `kubectl rollout`.

The cause isn't capacity. It's the **default rollout strategy** plus a **missing readiness gate**. A Deployment created without an explicit `strategy` inherits defaults that were chosen to be *safe-ish and fast*, not zero-downtime — and without a `readinessProbe` the control plane considers a pod "ready" the instant its container process starts, long before the app inside can actually serve a request.

This challenge is the `maxUnavailable: 0` combination from Course 01's *Make It Survive*, taken one layer deeper: here you also add **`minReadySeconds`** so a new pod has to *stay* healthy for a beat before the rollout counts it and marches on.

## What the defaults actually do to you

A `RollingUpdate` Deployment with no explicit strategy gets these defaults:

| Field | Default | What it means during a rollout |
|-------|---------|--------------------------------|
| `strategy.type` | `RollingUpdate` | Replace pods incrementally (good) |
| `rollingUpdate.maxUnavailable` | `25%` | You may drop to 75% of desired capacity *mid-rollout* |
| `rollingUpdate.maxSurge` | `25%` | You may temporarily run up to 125% of desired |
| `minReadySeconds` | `0` | A pod counts as available the moment it reports Ready — zero soak time |

With 3 replicas, `maxUnavailable: 25%` rounds **down** to 0 pods unavailable — so defaults aren't always catastrophic. The real killer is the second half: **no `readinessProbe`.** Without one, "Ready" means "the container's PID 1 is running," so the rollout happily terminates an old pod and routes traffic to a brand-new one that is still binding its port or warming a cache. That's your 502.

```
   DEFAULTS, no readinessProbe                 TARGET: maxUnavailable:0 + probe + minReadySeconds
   (traffic hits a cold pod)                   (never below capacity, never a cold pod)

   old old old                                  old old old
   old old  X   <- killed, replaced by          old old old  +NEW   <- surge: add before removing
   old old new  <- cold, 502s while warming      old old old  +NEW(ready, soaked 5s)
   old old new(ready eventually)                 old old  X    NEW   <- only now evict an old one
                                                  ... repeat, capacity never dips ...
```

## Mission

The setup script plants a Deployment `web` in namespace `dojo-rollout` with **default rollout settings and no health checks** — the exact anti-pattern above. Bring it to a genuinely zero-downtime configuration.

## Target state

The verifier accepts your work only when **all** of these are true for Deployment `web` in `dojo-rollout`:

1. **`strategy.rollingUpdate.maxUnavailable: 0`** — during a rollout, never drop below desired capacity. Pair it with **`maxSurge: 1`** so the rollout can still make progress (add a new pod *before* retiring an old one).
2. **A `readinessProbe`** on the container — so a pod only receives traffic once it can actually answer, which is what makes the surge safe.
3. **`minReadySeconds` ≥ 5** — a freshly-Ready pod must stay healthy for at least 5 seconds before the rollout treats it as available and proceeds. This catches the pod that passes one probe and then crashes.
4. **`readyReplicas == spec.replicas`** — the Deployment is fully rolled out and every desired pod is Ready when you run the verifier (no half-finished rollout).

## Rules of engagement

- Work in namespace `dojo-rollout` (the setup script creates it and plants `web`).
- You may `kubectl edit`, `kubectl patch`, or write YAML and `kubectl apply` it — the verifier only inspects final state.
- The image is `nginx:1.27-alpine`, serving on port 80 — use `/` on port `80` as the readiness path.
- Don't lower `replicas`. Keep it at the planted value so there's real capacity to protect.

## Why `minReadySeconds` is the part people skip

`maxUnavailable: 0` + a `readinessProbe` is the famous combo, and it's necessary — but it has a gap. A pod can pass its *first* readiness probe and then fall over a second later (a slow dependency, a JIT warmup that OOMs, a config it only reads on first request). With `minReadySeconds: 0`, the rollout has already counted that pod and killed an old one by the time it dies — so you're now genuinely below capacity with no old pod to fall back to.

`minReadySeconds: 5` forces the pod to **stay** Ready for 5 continuous seconds before the Deployment controller considers it "available" and advances the rollout. It's cheap insurance that turns "passed one probe" into "has been stably serving." Set it to roughly your app's observed time-to-first-wobble; 5s is a sane floor for most HTTP services.

When the Deployment is in the target state, run the verifier (section 3 above). It inspects your live cluster and prints the flag only if every check passes.
