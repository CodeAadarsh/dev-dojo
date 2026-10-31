# Autoscale Under Load

Your team runs a web service that gets slammed every time marketing sends a campaign. Right now the on-call ritual is: get paged, eyeball the dashboard, run `kubectl scale deploy web --replicas=N`, guess at N, and scale back down an hour later. That's textbook **toil** — manual, repetitive, reactive, and it scales linearly with every new service. Worse, the human is always *behind* the load.

The deployment already has the one prerequisite that makes autoscaling possible: **CPU resource requests**. Without a request, there's no denominator for "CPU utilization" and an HPA has nothing to target. What's missing is the autoscaler itself.

Your job: replace the pager with a **HorizontalPodAutoscaler** so the platform scales `web` on CPU demand, hands-free.

## Target state

The verifier will accept your work only when **all** of these are true in namespace `dojo-hpa`:

1. **A HorizontalPodAutoscaler exists** (`autoscaling/v2`) in `dojo-hpa`.
2. Its **`scaleTargetRef`** points at the `web` Deployment (`kind: Deployment`, `name: web`).
3. It has a **CPU metric** of type `Resource`, name `cpu`, using **`averageUtilization`** (not `AverageValue`).
4. The target utilization is **sane**: between 1 and 90 (the brief suggests `50`).
5. **`minReplicas` ≥ 2** (never serve from a single pod) and **`maxReplicas` ≤ 5**, with `maxReplicas > minReplicas` so there's actual headroom to scale into.

## Rules of engagement

- Work in namespace `dojo-hpa` (the setup script creates it and plants the `web` Deployment).
- You may use `kubectl autoscale` or write an `autoscaling/v2` manifest and `kubectl apply` it. Either is accepted — the verifier only inspects the final HPA **spec**, not live scaling behavior.
- Don't touch the Deployment's CPU requests — they're already set correctly (`100m`). The HPA reads them.

## A note on actually seeing it scale

The verifier checks the HPA **spec**, not real scaling, on purpose — so you don't need a metrics pipeline to pass. But in a real cluster (and to make `kubectl top` and live scaling work) you need **metrics-server** running, because the HPA controller reads pod CPU from the metrics API every 15s:

```bash
kubectl top pods -n dojo-hpa     # ERROR here = metrics-server not installed
```

If that errors, the HPA will sit at `<unknown>/50%` for its current utilization and never scale — not because your spec is wrong, but because nothing is feeding it metrics. Installing metrics-server (and generating load to watch it scale) is covered in the solution as an optional "prove it" step. For the flag, a correct spec is enough.

> **Why this matters:** an HPA is the canonical example of turning toil into a declarative control loop. The human who used to scale by hand becomes a one-time author of a spec, and the control plane does the reconciliation forever. Get the *metric* and the *bounds* right and you've eliminated a whole class of 3am pages.

When the HPA is in the target state, run the verifier (section 3 above). It inspects the live HPA and prints the flag only if every check passes.
