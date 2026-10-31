# Pods, Deployments & the Reconciliation Loop

> **Module 03 · Course 01** — The single idea that makes Kubernetes *Kubernetes* is the **reconciliation loop**: you declare desired state, controllers continuously drive observed state toward it, forever. Everything else — Deployments, rollouts, self-healing, the three probes — is a consequence of that loop. Get the loop in your bones and the rest stops being magic.

You run Deployments at work. This module goes slow on the parts that cause 3 a.m. pages: the exact semantics of each probe, the two distinct failure modes they cause when misconfigured (crashloop vs silent traffic black-hole), and what `rollout undo` is actually undoing.

---

## The reconciliation loop: desired vs observed

A Kubernetes controller is a `while true` loop. It reads **desired state** (your spec in etcd), observes **actual state** (what's really running), computes the diff, and takes action to close it — then does it again, forever.

```
                 ┌───────────────────────────────────────────┐
                 │                                             │
                 ▼                                             │
     ┌───────────────────┐    observe    ┌──────────────────┐ │
     │  DESIRED STATE     │◄──────────────│  OBSERVED STATE  │ │
     │  spec: replicas:3  │               │  2 pods running  │ │
     └─────────┬──────────┘               └──────────────────┘ │
               │ diff = "need 1 more pod"                       │
               ▼                                                │
     ┌───────────────────┐                                     │
     │  ACT: create pod   │─────────────────────────────────────┘
     └───────────────────┘        (loop again, forever)
```

Two properties fall out of this, and both matter operationally:

- **Level-triggered, not edge-triggered.** The controller doesn't react to the *event* "a pod died." It reacts to the *fact* "observed ≠ desired." Miss an event? Next loop still sees the gap and fixes it. This is why Kubernetes is robust to the controller restarting, missing a watch, or an API hiccup — it re-derives reality every pass.
- **Self-healing is just the loop running.** `kubectl delete pod` under a Deployment doesn't "delete your app" — it widens the diff, and the ReplicaSet controller makes a replacement within the same loop. You can't win a fight with a controller; you edit the desired state instead.

> **The imperative reflex is the bug.** `kubectl delete pod web-xyz` feels like an action with a result. It's really a *temporary* perturbation the loop immediately undoes. To actually remove the pod, change desired state: scale the Deployment, or delete the Deployment. Fight the spec, not the symptom.

---

## Pod → ReplicaSet → Deployment

Three objects, three jobs. Each layer manages the one below it through its own reconcile loop.

| Object | Responsible for | You should hand-write it... |
|--------|-----------------|------------------------------|
| **Pod** | One scheduling unit: 1+ containers sharing network + storage | Almost never — it's mortal, unmanaged, won't reschedule |
| **ReplicaSet** | Keeping *N* identical pods alive (matching a selector) | Almost never directly — the Deployment owns it |
| **Deployment** | Managing ReplicaSets to roll out new versions safely | **Yes — this is your unit of deploy** |

The relationship, and why there's a ReplicaSet in the middle at all:

```
Deployment  web            (declares the pod template + rollout strategy)
   │  owns, one "current" + old ones kept for rollback
   ├── ReplicaSet web-7d4  (template hash 7d4, replicas: 3)  ◄── current
   │     ├── Pod web-7d4-aa
   │     ├── Pod web-7d4-bb
   │     └── Pod web-7d4-cc
   └── ReplicaSet web-9f1  (template hash 9f1, replicas: 0)  ◄── previous (kept)
```

A rollout is a Deployment **creating a new ReplicaSet** (its selector includes a hash of the pod template) and shifting replicas from old to new per the strategy. The old ReplicaSet is scaled to 0, **not deleted** — that scaled-to-0 history is exactly what `rollout undo` scales back up. `revisionHistoryLimit` (default 10) caps how many old ReplicaSets are retained.

---

## `kubectl rollout`: status, history, undo

```bash
# watch a rollout progress to completion (exits non-zero if it stalls/fails)
kubectl -n dojo-apps rollout status deploy/web

# see the revision history (one row per retained ReplicaSet)
kubectl -n dojo-apps rollout history deploy/web

# inspect what a specific revision's pod template was
kubectl -n dojo-apps rollout history deploy/web --revision=3

# roll back to the immediately previous revision...
kubectl -n dojo-apps rollout undo deploy/web
# ...or to a specific one
kubectl -n dojo-apps rollout undo deploy/web --to-revision=2

# pause mid-rollout (bake a canary), then resume
kubectl -n dojo-apps rollout pause deploy/web
kubectl -n dojo-apps rollout resume deploy/web
```

Two things that trip people up:

- **`rollout undo` changes the spec.** It's not a time machine — it re-applies the old pod template as the *new* desired state, producing a new revision that happens to equal an old one. Your GitOps source of truth is now out of sync; fix the manifest too.
- **Add a change-cause for readable history.** Set `kubernetes.io/change-cause` (via annotation or `--record`-style tooling) so `rollout history` shows *why* each revision exists instead of `<none>`.

> **`revisionHistoryLimit: 0` deletes your undo button.** Some teams set it low to reduce clutter, not realizing that scaled-to-0 ReplicaSets *are* the rollback capability. Keep at least 2–3 unless you have an external deploy system that re-rolls old versions.

**Edge case — the double-zero deadlock.** `maxUnavailable: 0` (never drop below desired capacity) is great for availability, but pair it with `maxSurge: 0` and you've asked for a rollout that can neither remove an old pod *nor* add a new one — the rollout wedges at 0% progress with no error message. You need headroom on at least one side; `maxSurge: 1, maxUnavailable: 0` is the zero-downtime default you actually want.

> **War story.** A team set `progressDeadlineSeconds: 60` on a service whose image pull from a cold regional registry took ~90s on a freshly-scaled node. Deploys "failed" every time the scheduler happened to land a pod on a node without the layer cached — `Progressing=False, reason=ProgressDeadlineExceeded` — even though those pods came up healthy two minutes later. Worse, the CI pipeline read the non-zero `rollout status` exit code and auto-triggered a rollback *on top of* a rollout that was actually succeeding, leaving two ReplicaSets scaling against each other. `progressDeadlineSeconds` is not a health signal; it's a patience budget. Size it above your worst-case cold-pull + boot, and never wire an auto-rollback to it without also confirming pod readiness.

---

## The three probes — precise semantics and failure modes

This is the highest-leverage section in the module. Each probe answers a different question, runs on its own schedule, and **fails in a different way**.

| Probe | Question it answers | On failure | Default-ish cadence |
|-------|--------------------|-----------|---------------------|
| **startup** | "Has the app *finished booting* yet?" | Kill container (after threshold) — but **suspends** liveness/readiness until it first succeeds | `periodSeconds: 10`, `failureThreshold: 3` |
| **liveness** | "Is the app *wedged* and needs a restart?" | **Restart** the container (per `restartPolicy`) | `initialDelaySeconds: 0`, `periodSeconds: 10`, `failureThreshold: 3`, `timeoutSeconds: 1` |
| **readiness** | "Can the app *serve traffic right now*?" | Remove the pod from **Service Endpoints** (no restart) | same cadence as liveness |

```
startupProbe        liveness/readiness suspended ──────────► active
   │  (app booting, up to failureThreshold*period)           │
   ▼                                                          ▼
 [boot OK] ──────────────────────────────────────────────────┤
                                                              │
   liveness fails  ──► kubelet RESTARTS the container         │  (restart loop)
   readiness fails ──► endpoints controller PULLS pod from    │  (no restart,
                       the Service; traffic stops; pod stays  │   just no traffic)
```

### Failure mode A — liveness misconfigured → **crashloop**

A liveness probe that's too aggressive (short `initialDelaySeconds`, slow app, or it checks a dependency) kills a *healthy-but-busy* app. The kubelet restarts it, the new container is also killed before it's ready, and you get `CrashLoopBackOff` — an outage you *caused*.

```yaml
# ✗ liveness that checks a DB connection = cascading restart storm when the DB blips
livenessProbe:
  httpGet: { path: /healthz/deep, port: 8080 }   # hits the database
# A DB hiccup now RESTARTS every pod instead of just draining traffic.
```

**Rule:** liveness must be *shallow and local* — "is my event loop responsive," never "is my downstream healthy." Put dependency checks in **readiness**, where the consequence is "stop sending me traffic," not "reboot me."

### Failure mode B — readiness misconfigured → **silent traffic black-hole**

The inverse and sneakier: **no readiness probe at all.** Kubernetes considers the pod Ready the instant the container process starts, adds it to Service Endpoints, and routes traffic to an app that hasn't loaded config / warmed its cache / connected to its DB. Users get 502s; the pod looks `Running` and `1/1` in a hurried glance. Nothing restarts, nothing alerts — the requests just vanish into a pod that isn't listening yet.

```yaml
# ✓ readiness gates traffic on actual readiness; pairs with maxUnavailable:0 for zero-downtime
readinessProbe:
  httpGet: { path: /ready, port: 8080 }
  initialDelaySeconds: 2
  periodSeconds: 5
  failureThreshold: 3
```

### Startup probe — for slow starters

Legacy apps that take 60s to boot force a dilemma: a liveness `initialDelaySeconds` long enough to survive boot is also too slow to catch a wedge later. The **startup probe** resolves it — it runs first, *holds off* liveness/readiness entirely until it succeeds once, then hands over to a tight liveness cadence.

```yaml
startupProbe:
  httpGet: { path: /healthz, port: 8080 }
  periodSeconds: 10
  failureThreshold: 30        # up to 300s to boot, then liveness takes over at 10s cadence
```

> **The mental shortcut:** liveness = *restart me*, readiness = *route to me*, startup = *wait for me*. Misfiled liveness logic causes crashloops; missing readiness causes black-holes. Both pages look like "the app is down" — the fix is opposite.

**Two probe gotchas that bite in review:** a **TCP** probe only proves the port is *open*, not that the app behind it can serve — a wedged server often still holds its listening socket, so a TCP liveness probe will happily call a hung process healthy. And an **exec** probe forks a process in the container on every `periodSeconds`; a heavy exec probe (a `curl`, a shell pipeline) on a dense node adds real CPU and can itself time out under load, producing *phantom* failures that look like the app is sick when it's the probe that's starving. Prefer `httpGet` against a cheap, dependency-free handler, and remember `timeoutSeconds` defaults to **1** — a probe that occasionally takes 1.2s will flap.

---

## initContainers — run-to-completion setup

`initContainers` run **sequentially, to completion, before any app container starts.** Each must exit 0 or the Pod restarts the init sequence (subject to `restartPolicy`). Use them for ordering and setup that must finish first.

```yaml
spec:
  initContainers:
    - name: wait-for-db
      image: busybox:1.36
      command: ['sh', '-c', 'until nc -z postgres 5432; do echo waiting; sleep 2; done']
    - name: run-migrations
      image: ghcr.io/acme/migrate:1.4.2
      command: ['/migrate', 'up']
  containers:
    - name: app
      image: ghcr.io/acme/app:1.4.2
```

```
 time ──►
 [ init: wait-for-db ] ✓  [ init: run-migrations ] ✓  [ app container starts ]
   (blocks)                 (blocks)                     (and stays running)
```

Init containers see the same Volumes and network, so they're the right place to fetch config, clone a repo into a shared `emptyDir`, wait on a dependency, or run one-shot migrations — work the app shouldn't carry in its own image or startup path.

---

## Multi-container pods: sidecar and ambassador

Containers in one Pod share network (one IP, `localhost`) and can share Volumes — that locality is the entire reason to co-locate them rather than run separate Pods.

```
┌──────────────── Pod (one IP, shared volumes) ─────────────────┐
│                                                               │
│   ┌── app ──────┐   localhost:9090   ┌── sidecar ──────────┐  │
│   │  writes logs│ ─────────────────► │  log shipper / proxy │  │
│   │  to /var/log│   shared emptyDir   │  reads /var/log      │  │
│   └─────────────┘◄──────────────────►└──────────────────────┘  │
└───────────────────────────────────────────────────────────────┘
```

| Pattern | What the second container does | Real example |
|---------|-------------------------------|--------------|
| **Sidecar** | Augments the app, runs for the Pod's lifetime | Log shipper tailing a shared volume; service-mesh proxy (Envoy) |
| **Ambassador** | Proxies the app's *outbound* connections to the outside world | Local proxy that hides sharding/retries behind `localhost:6379` |
| **Adapter** | Reshapes the app's *output* for the outside world | Sidecar that converts app metrics into the Prometheus format |

> **Native sidecars (v1.28+).** A true sidecar is now an `initContainer` with `restartPolicy: Always` — it starts *before* app containers, stays running, and (critically) is torn down *after* them on shutdown, so your log shipper or mesh proxy outlives the app during termination instead of dying first and dropping the last logs. If your "sidecar" is a plain extra entry under `containers:`, startup/shutdown ordering is not guaranteed.

---

## Pod phases & `restartPolicy`

A Pod's `.status.phase` is a coarse lifecycle summary — not the same as container readiness.

| Phase | Meaning |
|-------|---------|
| `Pending` | Accepted, but not all containers running yet (scheduling, image pull, init containers) |
| `Running` | Bound to a node, at least one container running (**says nothing about Ready**) |
| `Succeeded` | All containers exited 0 and won't restart |
| `Failed` | All containers terminated, at least one non-zero / killed |
| `Unknown` | Node lost contact (usually a node/network problem) |

`restartPolicy` governs what the kubelet does when a container *exits* — and it's **Pod-wide**, set once:

| Policy | Behaviour | Used by |
|--------|-----------|---------|
| `Always` (default) | Restart on any exit, success or failure | Deployments / long-running services |
| `OnFailure` | Restart only on non-zero exit | Jobs that should retry until they succeed |
| `Never` | Never restart | Jobs where you handle retries yourself |

`CrashLoopBackOff` is not a phase — it's a *reason* inside a `Running`/`Waiting` pod where `restartPolicy: Always` keeps restarting a container that keeps exiting, with the kubelet backing off exponentially (10s, 20s, 40s … capped at 5 min). Read it as "the container starts then dies" and go to `kubectl logs --previous` and `kubectl describe` — the exit is upstream of Kubernetes, in your process or your liveness probe.

---

## Debugging Pods & Rollouts

Seven symptoms cover the overwhelming majority of pod-level pages. The trick is to stop guessing and let the object tell you: `describe` for the *events* (scheduling, pulls, probe failures, OOM), `logs --previous` for the *last words* of a container that already died, and `get ... -o jsonpath` for the one field that confirms your hypothesis.

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `CrashLoopBackOff` | App exits non-zero on boot (bad config, missing env/Secret, failed migration) — or liveness kills it before boot finishes | Read `logs --previous`; fix the exit; if boot is slow add a `startupProbe` |
| `Running` but restart count climbing, no app crash | Liveness probe failing on a healthy-but-busy app | Loosen liveness (`initialDelaySeconds`, `timeoutSeconds`); move dependency checks to readiness |
| `Running 1/1` but gets no traffic / users see 502s | No readiness probe, or readiness failing silently | Add/fix `readinessProbe` pointing at a cheap local path |
| `OOMKilled` (exit 137) | Container exceeded its memory *limit*, or node memory pressure | Raise `limits.memory`, fix the leak, or size the heap to the limit |
| Pod stuck `Pending` | No node fits: insufficient cpu/mem, taint, nodeSelector/affinity, or unbound PVC | `describe pod` → the `FailedScheduling` event names the exact reason |
| Rollout hangs forever at "waiting for rollout to finish" | New pods never go Ready (bad image, failing readiness, OOM) | `rollout status` + inspect the *new* ReplicaSet's pods |
| `ImagePullBackOff` / `ErrImagePull` | Wrong tag, private registry, or (on kind) image never loaded | Fix tag / add `imagePullSecrets`; on kind `kind load docker-image <img> --name dojo` |

### CrashLoopBackOff — read the last words

`CrashLoopBackOff` is not the error, it's the *backoff*. The real error is in the log of the container that already died:

```bash
kubectl -n dojo-apps describe pod web-xxx | sed -n '/Events/,$p'   # exit code + reason
kubectl -n dojo-apps logs web-xxx --previous                       # the actual crash
kubectl -n dojo-apps get pod web-xxx \
  -o jsonpath='{.status.containerStatuses[0].lastState.terminated.exitCode}{"\n"}'
```

Decode the exit code before theorizing: `1`/`2` = app threw on startup (read the log), `137` = SIGKILL (almost always OOMKilled — see below), `139` = SIGSEGV, `143` = SIGTERM (something asked it to stop — often a probe or an eviction). The backoff timer (10s → 20s → … → 5 min cap) means a pod that's been crashing a while is *slow* to retry — don't mistake a long quiet gap for "it recovered."

### Liveness killing a healthy pod

The nastiest variant: the app is *fine*, but a too-tight liveness probe keeps restarting it, and each restart makes the incident worse (cold caches, reconnection storms). The tell is in the events — restarts caused by the kubelet, not by the app crashing:

```bash
kubectl -n dojo-apps describe pod web-xxx | grep -iE 'liveness|killing|unhealthy'
# -> "Liveness probe failed: ..." / "Killing container ... failed liveness probe"
kubectl -n dojo-apps get pod web-xxx \
  -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}{"\n"}'   # "Error", code 143/137
```

If `logs --previous` is clean — no stack trace, no fatal line — but the container was killed, **the kubelet did it; the probe is the culprit, not the app.** Confirm by reading the probe cadence (`initialDelaySeconds`, `timeoutSeconds`, `failureThreshold`) and widening it, or remove the probe temporarily to prove the app itself is healthy.

### Stuck rollouts

`kubectl rollout status` blocks until the new ReplicaSet is fully Ready — or until `progressDeadlineSeconds` (default 600s) elapses, after which the Deployment condition flips to `Progressing=False, reason=ProgressDeadlineExceeded`. Critically, **hitting the deadline does NOT auto-roll-back** — it just marks the rollout failed and leaves the half-migrated state in place.

```bash
kubectl -n dojo-apps rollout status deploy/web --timeout=60s      # don't block forever
kubectl -n dojo-apps get rs -l app=web                            # which RS is scaling up, which is stuck
kubectl -n dojo-apps describe deploy web | grep -A3 Conditions
kubectl -n dojo-apps get pods -l app=web --field-selector=status.phase!=Running
```

Walk it: the *new* ReplicaSet (non-zero desired, zero available) holds the broken pods. `describe` one of them and you'll find the real reason — `ImagePullBackOff`, failing readiness, or `Pending`. The rollout isn't "stuck," it's correctly *refusing to proceed* because the new pods never became Ready. Fix the pod, or `rollout undo`.

### OOMKilled (exit 137)

```bash
kubectl -n dojo-apps get pod web-xxx \
  -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}{"\n"}'   # -> OOMKilled
kubectl -n dojo-apps describe pod web-xxx | grep -iE 'oom|limits|requests'
docker exec dojo-worker cat /sys/fs/cgroup/memory.max 2>/dev/null                 # node cgroup v2 limit
```

The kernel OOM-killer fires when the container crosses its `limits.memory`, **not** its request — the request only affects scheduling and QoS class. Two traps: (1) a JVM or Node process that reads the *node's* total RAM instead of its cgroup limit sizes its heap too big and gets killed on first GC — set `-XX:MaxRAMPercentage` or `--max-old-space-size` to fit the limit; (2) with *no* limit at all the kernel kills based on *node* pressure and may shoot an innocent neighbour — a `Guaranteed` QoS pod (requests == limits) is evicted last, which is why limits are a stability feature, not just a cost control.

### Pending pods — the scheduler couldn't place it

```bash
kubectl -n dojo-apps describe pod web-xxx | sed -n '/Events/,$p'
# -> "0/3 nodes are available: 3 Insufficient cpu" / "node(s) had untolerated taint" / "unbound PersistentVolumeClaim"
kubectl top nodes                       # needs metrics-server: labs/bootstrap/install-metrics-server.sh
kubectl -n dojo-apps get pvc            # a Pending PVC pins its pod Pending
```

The `FailedScheduling` event is never vague — it names the exact predicate that failed: insufficient resources, an untolerated taint, a nodeSelector/affinity with no match, or an unbound PVC. Don't guess; read the sentence. On the dojo cluster the usual culprit is resource `requests` that don't fit a worker — lower them or scale the workload down.

### ImagePullBackOff — and the kind-specific trap

```bash
kubectl -n dojo-apps describe pod web-xxx | grep -iE 'pull|image|back-off'
# -> "Failed to pull image ...: not found" / "unauthorized" / "ErrImagePull"
```

`ErrImagePull` is the first failed attempt; `ImagePullBackOff` is the kubelet backing off before retrying. Three distinct causes with three distinct fixes: a **wrong tag** (`not found` / `manifest unknown` — fix the tag; and never ship `:latest`, which makes "which image is actually running" unanswerable), a **private registry** (`unauthorized` — add an `imagePullSecrets` referencing a `docker-registry` Secret), or — the one unique to this lab — **an image you built locally that the cluster has never heard of.** kind nodes have their own containerd; your Mac's Docker images are not visible to them until you load them:

```bash
kind load docker-image myapp:dev --name dojo    # push the local image into the kind nodes
```

This is the single most common "but it's right there in `docker images`!" confusion on kind — the cluster and your host keep separate image stores.

> **War story.** A payments service started flapping `CrashLoopBackOff` across *every* pod simultaneously at 2 a.m. — the dashboard screamed "whole service down." But `logs --previous` was spotless: the app booted fine, served for ~40s, then exit 143. The liveness probe hit `/healthz`, and three weeks earlier `/healthz` had quietly been "improved" to also ping the primary database. The DB had a 3-second failover blip; every liveness probe in the fleet timed out *at the same instant*; the kubelet SIGTERM'd every pod together; cold processes then couldn't boot fast enough under the thundering reconnect load, and a 3-second database blip became a 25-minute outage we *manufactured ourselves*. The DB was healthy the whole time after second three. The fix was one line — move the dependency check out of liveness and into readiness. Liveness answers "am I wedged," never "is my database up."

---

## Checkpoint

You're ready for the challenges when you can, without looking anything up:

1. Explain level-triggered reconciliation and why deleting a managed pod doesn't remove your app.
2. Draw the Deployment → ReplicaSet → Pod ownership chain and say what `rollout undo` actually scales.
3. State what each of the three probes does on failure — restart, de-endpoint, or hold.
4. Name the misconfiguration that causes a crashloop vs the one that causes a silent traffic black-hole.
5. Explain why a liveness probe must never check a downstream dependency.
6. Say when you'd reach for an `initContainer` vs a native sidecar, and how their lifecycles differ.
7. Distinguish Pod *phase* (`Running`) from container *readiness*, and read `CrashLoopBackOff` correctly.
8. Given a `CrashLoopBackOff`, name the three commands you'd run first and say what exit code `137` vs `143` vs `1` each tells you.
9. Explain why a `Pending` pod is never a mystery, and where the scheduler writes the exact predicate that failed.
10. Tell apart "the app crashed" from "the kubelet killed a healthy app" using only `logs --previous` and the pod's `lastState`.

➡ With the loop, the probes, and the rollout mechanics internalized, the **Make It Survive** challenge is now a 10-minute exercise — go turn the fragile Deployment into one that shrugs off rollouts and node drains, and prove it with the verifier.
