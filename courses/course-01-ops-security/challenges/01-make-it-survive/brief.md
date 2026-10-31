# Make It Survive

Ops just handed you a service that "keeps going down during deploys." You look at it and wince: **one replica, no health checks, no resource requests, no disruption budget.** Every rollout is a coin flip, and a single node drain takes it offline.

Your job: make the `web` Deployment in namespace `dojo-resilient` genuinely resilient, the way it should have shipped.

## Target state

The verifier will accept your work only when **all** of these are true for Deployment `web` in `dojo-resilient`:

1. **≥ 3 replicas** — no single pod is the whole service.
2. **A `readinessProbe`** on the container — so traffic is only sent to pods that are actually ready, which is what makes a rolling update seamless.
3. **`strategy.rollingUpdate.maxUnavailable: 0`** — during a rollout, never drop below the desired capacity.
4. **Resource `requests`** (cpu + memory) on the container — so the scheduler can place pods sanely and they get a QoS class better than *BestEffort*.
5. **A `PodDisruptionBudget`** protecting the app — so a voluntary disruption (node drain, cluster upgrade) can't evict all pods at once.

## Rules of engagement

- Work in namespace `dojo-resilient` (the setup script creates it).
- You may edit the live objects (`kubectl edit`) or — better practice — write YAML and `kubectl apply` it. Either is accepted; the verifier only inspects final state.
- The image is `nginx:1.27-alpine` which serves on port 80 — use `/` as the readiness path.

When you believe the cluster is in the target state, run the verifier (section 3 above). It inspects your live cluster and prints the flag only if every check passes.
