# Zero-Downtime Rollouts & Rollbacks

> **Module 03 · Course 02** — "Deploy" and "no downtime" are supposed to be the same sentence. In practice most teams ship a `RollingUpdate` with default knobs, a half-wired readiness probe, and no idea what `progressDeadlineSeconds` does — and then act surprised when a bad image takes the service down for ninety seconds before anyone notices. This module is the exact mechanics: the surge/unavailable arithmetic the Deployment controller runs, how readiness *gates* the whole dance, how the controller decides a rollout is "stuck," and how to get back to safety in one command. You already do rollouts at work; this is the part that separates "it usually works" from "it provably can't drop a request."

A Deployment rollout is not magic — it's a controller reconciling two ReplicaSets (old and new) toward a target, bounded by two numbers you set, gated by one signal your pods emit. Understand those three things and every weird rollout behaviour you've ever seen becomes obvious.

---

## The anatomy: Deployment → ReplicaSet → Pod

A `kubectl apply` that changes the pod template does **not** edit pods in place. The Deployment controller creates a **new ReplicaSet** and shifts replicas from the old RS to the new one, pod by pod, under your constraints. This indirection is the whole reason rollback is instant — the old ReplicaSet is still sitting there at 0 replicas, ready to scale back up.

```
  Deployment "web"  (desired: template v2, replicas: 4)
      │
      ├── ReplicaSet web-aaaa  (template v1)  replicas: 4 → 3 → 2 → 1 → 0   [kept for rollback]
      └── ReplicaSet web-bbbb  (template v2)  replicas: 0 → 1 → 2 → 3 → 4   [new, ramping up]
                                                   ▲
                 each step bounded by maxSurge / maxUnavailable,
                 each new pod must pass readiness before it "counts"
```

A template change (image, env, resources, labels) spawns a new RS. A **replica-count-only** change (scaling) does *not* — it just resizes the current RS. This is why `kubectl scale` never shows up in `rollout history`: no new template, no new revision.

```bash
kubectl -n dojo-rollout get rs -o wide          # see both ReplicaSets and their revision
kubectl -n dojo-rollout get rs --show-labels | grep pod-template-hash   # the hash that distinguishes them
```

---

## maxSurge & maxUnavailable — the arithmetic, exactly

These two knobs under `spec.strategy.rollingUpdate` are the entire budget for a rolling update. They answer: *how many extra pods may I create above desired* (`maxSurge`) and *how many below desired may I drop* (`maxUnavailable`). Both accept an absolute integer or a percentage (rounded — surge **up**, unavailable **down**).

```
  desired replicas = R
  maxSurge        → ceil   → max pods that may exist AT ONCE = R + maxSurge
  maxUnavailable  → floor  → min pods that must stay AVAILABLE = R - maxUnavailable

  INVARIANT the controller never violates:
     (pods existing)      ≤ R + maxSurge
     (pods available)     ≥ R - maxUnavailable
```

The two numbers define the rollout's *personality*:

| Config | Behaviour | Needs extra capacity? | Risk |
|--------|-----------|-----------------------|------|
| `maxSurge: 25%`, `maxUnavailable: 25%` (**default**) | Fast, cheap — drops up to 25% while surging 25% | No (can shrink) | Dips below full capacity mid-rollout |
| `maxSurge: 1`, `maxUnavailable: 0` | **Zero-downtime**: add a ready pod *before* removing an old one | Yes (+1 pod of headroom) | None to availability; needs room to surge |
| `maxSurge: 0`, `maxUnavailable: 1` | Scale-down-first: never exceeds R pods | No | Always runs below desired during rollout |
| `maxSurge: 100%`, `maxUnavailable: 0` | Blue/green-ish: stand up a full second set, then flip | Yes (2× capacity briefly) | None to availability; expensive |

**They may not both be zero** — that's a rollout that can neither add nor remove a pod, so the controller rejects it (`may not be 0 when maxSurge is 0`). The zero-downtime recipe is specifically `maxUnavailable: 0` + `maxSurge ≥ 1`: the controller is *forbidden* from dropping below desired capacity, so it must bring a new pod to Ready before it retires an old one.

Trace a 4-replica rollout with `maxSurge: 1, maxUnavailable: 0`:

```
  step 0:  v1 v1 v1 v1                      (4 available, desired 4)
  step 1:  v1 v1 v1 v1 [v2 starting]        (surge +1 → 5 exist, still 4 available)
  step 2:  v1 v1 v1 v1  v2✓                 (v2 passed readiness → now 5 available)
  step 3:  v1 v1 v1      v2✓   (-1 v1)       (retire one v1, back to 4 available)
  step 4:  v1 v1 v1 [v2 starting] v2✓        (surge again)
  ...repeat... never dips below 4 available. THAT is zero-downtime.
```

Contrast with the **default** `25%/25%` on the same 4 replicas: the controller may immediately kill one old pod (down to 3 available) *before* a new one is Ready. If your readiness probe is slow or the new image is broken, you serve from 3 pods — or fewer — for the whole rollout. For anything latency- or capacity-sensitive, **the default is not zero-downtime**; you must opt into `maxUnavailable: 0`.

---

## Readiness gating — the signal that makes it seamless

The surge/unavailable math is only honest if "available" means "can actually serve traffic." That's the readiness probe's entire job: a pod is **Ready** only when its `readinessProbe` passes, and the rollout controller counts **Ready** pods, not **Running** ones. No readiness probe → a pod is "Ready" the instant its process starts → the controller cheerfully retires old pods while the new ones are still loading config, warming caches, or failing to connect to the DB. That is the single most common cause of a "rollout that dropped traffic."

```
  Running  = the container process started
  Ready    = the readinessProbe passed → Endpoints controller adds the pod IP to the Service
                                        → the rollout controller counts it as "available"

  no readinessProbe  ⇒  Ready == Running  ⇒  traffic + rollout credit the instant PID 1 exists
```

The three probes, and the one everyone conflates:

| Probe | Question it answers | On failure |
|-------|---------------------|------------|
| **startup** | "Has the app finished its slow boot?" | Hold off liveness/readiness until it passes (protects slow starters from being killed) |
| **readiness** | "Should this pod receive traffic *right now*?" | Remove pod from Service Endpoints — **no restart**, just no traffic |
| **liveness** | "Is this pod wedged and beyond recovery?" | **Restart** the container |

The classic self-inflicted outage: pointing **liveness** at a deep health check (DB, downstream deps). When the DB blips, liveness fails, Kubernetes *restarts every pod at once*, and now you've turned a 10-second dependency hiccup into a full restart storm. **Liveness should be shallow and local** ("is my event loop alive?"); **readiness** is where you check dependencies, because failing readiness just removes you from rotation without the kill.

Two timing fields that quietly decide rollout safety:

- **`minReadySeconds`** — a pod must stay Ready for *this many seconds* before the controller treats it as available and proceeds to the next one. This is your guard against the "Ready then immediately crashes" flapper: without it, a pod that passes one readiness check and dies 2 seconds later still counts, and the rollout marches on over a cliff. Set it to a few seconds to force the new version to *prove it can stay up* before more old pods retire.
- **`progressDeadlineSeconds`** (default **600**) — if the Deployment makes *no forward progress* for this long, the controller marks the rollout `Failed` with condition `Progressing=False, reason=ProgressDeadlineExceeded`. Crucially, this does **not** auto-rollback — it just stops lying that things are fine and flips a status you can alert on. Lower it (e.g. 120) so a wedged rollout surfaces in two minutes instead of ten.

```yaml
spec:
  minReadySeconds: 10            # new pod must hold Ready for 10s before we proceed
  progressDeadlineSeconds: 120   # no progress for 2min → mark rollout Failed (alertable)
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0          # the zero-downtime invariant
```

> **readiness vs liveness, said once more because it matters:** if you remember one thing, make it *"readiness controls traffic, liveness controls restarts, and dependencies belong in readiness, never liveness."* Nearly every "our deploy caused an outage" postmortem I've read traces back to this line being violated.

---

## Driving rollouts: status, history, undo

The `kubectl rollout` subcommands are the whole operator interface. Know them cold — in an incident you reach for `undo` under pressure and there's no time to read the help.

```bash
# watch a rollout to completion — exits non-zero if it fails (great for CI gates)
kubectl -n dojo-rollout rollout status deploy/web --timeout=120s

# the revision log — each row is a past pod-template
kubectl -n dojo-rollout rollout history deploy/web
kubectl -n dojo-rollout rollout history deploy/web --revision=3   # full template of rev 3

# INSTANT rollback: scale the previous ReplicaSet back up, current down
kubectl -n dojo-rollout rollout undo deploy/web
kubectl -n dojo-rollout rollout undo deploy/web --to-revision=3   # to a specific good revision

# pause mid-rollout (bake a canary / batch multiple edits into one rollout), then resume
kubectl -n dojo-rollout rollout pause deploy/web
kubectl -n dojo-rollout rollout resume deploy/web

# force a re-roll with no spec change (e.g. to repull an image or cycle pods)
kubectl -n dojo-rollout rollout restart deploy/web
```

Two things people trip on:

- **`rollout history` shows empty `CHANGE-CAUSE` unless you record it.** The cause is populated from the `kubernetes.io/change-cause` annotation. Set it per change (`kubectl annotate deploy/web kubernetes.io/change-cause="bump to v2.3.1 for CVE fix"`) or your history is a list of anonymous revision numbers that tell you nothing at 3am.
- **`undo` is bounded by `revisionHistoryLimit`** (default 10). The controller keeps that many old ReplicaSets around for rollback; older ones are garbage-collected and are gone forever. If you set `revisionHistoryLimit: 0` to "keep things tidy," you have *disabled rollback*. Leave it at a sane 10.

> **Rollback is faster than roll-forward — use it.** The on-call instinct under pressure is often to debug the new version live. Don't. `rollout undo` scales a *known-good* ReplicaSet that already has warm pods and a proven image; it's seconds to safety. Debug the bad revision *after* you've restored service, from the ReplicaSet that's now parked at 0. Mean-time-to-recovery is a reliability metric; `undo` is usually the lowest-MTTR move you have.

---

## Canary & blue-green — beyond the built-in RollingUpdate

A plain `RollingUpdate` is a *gradual replacement* — it does not give you a stable "10% of traffic to the new version while I watch error rates" control, because traffic split follows pod count, not a policy you set. The two patterns that do, and how they actually get built:

```
  ROLLING (built-in)     gradually swap v1→v2 pods behind ONE Service.
                         Traffic split ≈ pod ratio. No explicit control. Simple, free.

  CANARY                 run a SMALL v2 deployment beside full v1, send a FRACTION of
                         traffic to it, watch SLOs, then ramp. Needs a traffic splitter
                         (Ingress canary annotations, Istio/Linkerd VirtualService,
                         Argo Rollouts, or just replica-count weighting behind one Service).

  BLUE/GREEN             stand up a FULL v2 ("green") beside full v1 ("blue"), test green
                         privately, then FLIP the Service selector green in one atomic switch.
                         Instant cutover, instant rollback (flip back), but needs 2× capacity.
```

| | Rolling | Canary | Blue/Green |
|---|---------|--------|-----------|
| Extra capacity | ~0–25% | small (canary %) | **2×** (full duplicate) |
| Traffic control | by pod ratio only | precise % / header-based | 0% then 100% (atomic flip) |
| Blast radius of a bad deploy | whole fleet, gradually | just the canary slice | zero until flip, then all |
| Rollback speed | `undo` (seconds) | shift traffic off canary | flip selector back (instant) |
| Built into core k8s? | **yes** | no (needs mesh/Ingress/Argo) | no (DIY selector flip or Argo) |

The poor-man's blue/green with nothing but core objects: two Deployments (`web-blue`, `web-green`) and one Service whose selector you flip:

```bash
# green is tested and healthy; cut all traffic over in one atomic edit:
kubectl -n dojo-rollout patch service web -p '{"spec":{"selector":{"app":"web","color":"green"}}}'
# regret it? flip back instantly:
kubectl -n dojo-rollout patch service web -p '{"spec":{"selector":{"app":"web","color":"blue"}}}'
```

For anything serious — automated SLO-gated canary analysis, metric-driven ramp, automatic abort — you reach for **Argo Rollouts** or **Flagger**, which replace the Deployment's rollout logic with a controller that reads your Prometheus/metrics and promotes or aborts on your golden signals. That's the natural successor to Course 02's SLO module: the canary *is* your error budget, enforced automatically.

---

## Debugging rollouts

Rollouts fail in a small number of recognisable ways. The first move is always `rollout status` (does the controller think it's progressing?) then `get rs` (which ReplicaSet is stuck and at what count?) then the pods of the *new* RS (why won't they go Ready?).

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `rollout status` hangs; new pods `Pending`/`ImagePullBackOff`/`CrashLoop` | Bad image tag, missing secret/config, insufficient resources for new RS | `describe` a new-RS pod; fix the image/config/requests; or `rollout undo` |
| Rollout wedged with new pods `Running` but never `Ready` | readinessProbe wrong (bad path/port, too-tight timing) or app genuinely unhealthy | Fix probe or app; `maxUnavailable: 0` *correctly* halts the rollout rather than dropping traffic |
| Rollout marked `Failed` / `ProgressDeadlineExceeded` | No forward progress within `progressDeadlineSeconds` | Read the real reason in new-RS pods; fix; the Deployment keeps retrying, or `undo` |
| Pods flap Ready→NotReady→Ready, rollout crawls or thrashes | Flapping readiness (too-short timeouts, app warming) — and no `minReadySeconds` | Loosen probe `timeoutSeconds`/`periodSeconds`; set `minReadySeconds` so a pod must *stay* Ready |
| Traffic drops *during* a rollout that "succeeded" | No readiness probe, or `maxUnavailable` too high → old pods retired before new ones serve | Add a real readinessProbe; set `maxUnavailable: 0`, `maxSurge: 1` |
| `rollout undo` does nothing / "no rollout history" | `revisionHistoryLimit: 0`, or only one revision exists | Restore a sane `revisionHistoryLimit`; roll forward to a fixed image instead |
| 502/connection-reset on the pods being *removed* | No `preStop` / graceful shutdown; pod killed while serving in-flight requests | Add `preStop` sleep + honour SIGTERM; raise `terminationGracePeriodSeconds` |

### Diagnose each — the exact commands

**Is it even progressing?** The conditions block is the controller's own verdict:

```bash
kubectl -n dojo-rollout rollout status deploy/web --timeout=5s        # non-zero exit = not done
kubectl -n dojo-rollout get deploy web -o jsonpath='{range .status.conditions[*]}{.type}={.status} ({.reason}){"\n"}{end}'
# Available=True (MinimumReplicasAvailable)
# Progressing=False (ProgressDeadlineExceeded)   ← the rollout is declared failed
```

**Which ReplicaSet is stuck, and why won't its pods go Ready?** Follow the new RS down to a concrete pod event:

```bash
kubectl -n dojo-rollout get rs -o wide     # the new RS shows DESIRED>CURRENT or CURRENT>READY
NEWRS=$(kubectl -n dojo-rollout get rs -o jsonpath='{range .items[?(@.spec.replicas>0)]}{.metadata.name}{" rev="}{.metadata.annotations.deployment\.kubernetes\.io/revision}{"\n"}{end}' | sort -t= -k2 -n | tail -1 | cut -d' ' -f1)
kubectl -n dojo-rollout describe rs "$NEWRS" | sed -n '/Events:/,$p'
# then a concrete pod from that RS:
kubectl -n dojo-rollout get pods -l app=web -o wide
kubectl -n dojo-rollout describe pod <new-pod> | sed -n '/Events:/,$p'   # ImagePull? Probe failed? Scheduling?
kubectl -n dojo-rollout logs <new-pod> --previous                        # crashloop logs pre-restart
```

**Flapping readiness.** The probe is failing intermittently — the pod's conditions and recent events show the flap:

```bash
kubectl -n dojo-rollout get pod <pod> -o jsonpath='{range .status.conditions[*]}{.type}={.status}{" "}{end}{"\n"}'
kubectl -n dojo-rollout describe pod <pod> | grep -iE 'readiness|unhealthy|probe'
# Warning Unhealthy: Readiness probe failed: HTTP probe failed with statuscode: 503
kubectl -n dojo-rollout get deploy web -o jsonpath='{.spec.template.spec.containers[0].readinessProbe}{"\n"}'
```

If the app just needs longer to warm, raise `periodSeconds`/`failureThreshold` and add `minReadySeconds`; if it's genuinely 503-ing, the new version is broken — `undo`.

**Rollback, cleanly.** Confirm what you're going back to *before* you pull the trigger, then verify it took:

```bash
kubectl -n dojo-rollout rollout history deploy/web
kubectl -n dojo-rollout rollout history deploy/web --revision=2   # inspect the target's template/image
kubectl -n dojo-rollout rollout undo deploy/web --to-revision=2
kubectl -n dojo-rollout rollout status deploy/web --timeout=120s
kubectl -n dojo-rollout get deploy web -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'   # confirm the image reverted
```

**Graceful-shutdown 502s.** If clients get resets on the pods being *removed*, the app isn't draining in-flight requests on SIGTERM. The sequence to internalize: on pod delete, Kubernetes *simultaneously* removes the pod from Endpoints and sends SIGTERM — but Endpoint propagation to kube-proxy/ingress is **not** instant, so for a short window traffic still arrives at a terminating pod. A tiny `preStop` sleep bridges that gap:

```yaml
      terminationGracePeriodSeconds: 30
      containers:
        - name: web
          lifecycle:
            preStop:
              exec:
                command: ["sh", "-c", "sleep 5"]   # keep serving while Endpoints de-registration propagates
```

> **War story.** A payments-adjacent service at SAP would throw a short burst of 502s on *every* deploy — maybe 50 failed requests over 3 seconds, every single rollout. It wasn't enough to blow the SLO so it lived as a "known cosmetic issue" for months. Two things were wrong and they compounded. First, the strategy was the default `25% maxUnavailable`, so the controller retired old pods *before* new ones were serving. Second — and this was the real cause — the app caught `SIGTERM` and exited *immediately*, cleanly, with in-flight requests still on the wire, and there was no `preStop`. So at the instant a pod was told to die, kube-proxy on some nodes still had its IP in the rotation for a few hundred milliseconds, and those requests hit a socket that had just closed. The fix was three lines: `maxUnavailable: 0` + `maxSurge: 1` to stop retiring capacity early, a `preStop: sleep 5` to keep serving during Endpoints propagation, and honouring SIGTERM with a graceful drain instead of an instant exit. Zero 502s on deploy afterward. The lesson that stuck: **"the pod is being deleted" and "the load balancer stopped sending it traffic" are two different events that do not happen at the same instant, and the gap between them is exactly where your deploy-time errors live.**

---

## Checkpoint

You're ready for the challenges when you can, without looking anything up:

1. Explain why a template change creates a new ReplicaSet but `kubectl scale` does not, and why that indirection makes rollback instant.
2. Compute, for `R` replicas with given `maxSurge`/`maxUnavailable`, the max pods that can exist and the min that stay available — and state why both can't be zero.
3. Give the exact `maxSurge`/`maxUnavailable` recipe for a true zero-downtime rollout and explain why the default `25%/25%` is not one.
4. Explain why the rollout controller counts **Ready** pods, not **Running**, and what goes wrong with no readiness probe.
5. State the difference between startup, readiness, and liveness probes, and why dependency checks belong in readiness, never liveness.
6. Explain what `minReadySeconds` protects against and what `progressDeadlineSeconds` does (and does *not*) do on expiry.
7. Run `rollout status`, read the Deployment `conditions`, and trace a stuck rollout from the new ReplicaSet down to a failing pod.
8. Roll back to a specific known-good revision and verify the image reverted, and explain why `revisionHistoryLimit: 0` is dangerous.
9. Contrast rolling, canary, and blue/green on capacity cost, traffic control, and rollback speed — and build a poor-man's blue/green with a Service selector flip.
10. Explain the Endpoints-propagation gap on pod termination and why `preStop` + graceful SIGTERM handling eliminates deploy-time 502s.

➡ You now have the reliability language (Module 01), the resource/QoS mechanics (Module 02), and the rollout machinery (Module 03). The challenges put them under load — where the theory either holds or pages you.
