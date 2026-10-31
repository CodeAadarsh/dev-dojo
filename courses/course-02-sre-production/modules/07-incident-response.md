# Incident Response & Production Debugging

> **Module 07 · Course 02** — The burn-rate alert from Module 06 just paged you. Something is on fire, a dashboard is red, and the clock on your error budget is running. This module is the muscle memory for the next ninety seconds and the next ninety minutes: a repeatable triage loop you can run while adrenaline is degrading your judgement, the tools that let you debug a container you can't even get a shell into, the instinct that saves the most time (roll back first, understand later), and the blameless postmortem that stops you having the same incident twice.

You already debug Kubernetes at work. What this module adds is *structure under pressure* — because the thing that actually fails during incidents is not your `kubectl` knowledge, it's your ability to apply it in order when your heart rate is 110 and someone from support is DMing you. The loop below is boring on purpose. Boring is what you want at 3am.

---

## The triage loop: describe → logs → events → top

Under pressure, people flail — they SSH into nodes, restart things at random, and read the wrong logs. The cure is a fixed loop you run *in order*, cheapest signal first, every single time, until the loop tells you where to go next.

```
        ┌─────────────────────────────────────────────────────┐
        │                                                       │
        ▼                                                       │
   ┌─────────┐    ┌────────┐    ┌────────┐    ┌──────┐          │
   │ describe│───▶│  logs  │───▶│ events │───▶│ top  │──────────┘
   └─────────┘    └────────┘    └────────┘    └──────┘
    WHY is it      WHAT did      WHAT did       IS it
    unhealthy?     the app say?  the cluster    starved?
    (events,       (stdout,      say? (sched,   (CPU/mem
     state,         crash         evict, pull,   vs limits)
     restarts)      --previous)    probe fails)
```

The four commands, and the one question each answers:

```bash
# 1. describe — the single highest-yield command. Read the Events at the bottom FIRST.
kubectl -n dojo-incident describe pod <pod>

# 2. logs — the app's own account. --previous is the one people forget.
kubectl -n dojo-incident logs <pod>
kubectl -n dojo-incident logs <pod> --previous      # the CRASHED container, pre-restart
kubectl -n dojo-incident logs <pod> -c <container>  # a specific container in a multi-container pod

# 3. events — cluster-wide history, most recent last. Catches what describe scopes out.
kubectl -n dojo-incident get events --sort-by=.lastTimestamp

# 4. top — is it resource-starved? (needs metrics-server)
kubectl top pod -n dojo-incident
kubectl top node
```

The discipline is **not skipping ahead.** The number of incidents "solved" by a random `kubectl delete pod` that actually just hid a `--previous` log line forever is enormous. `describe` → `logs --previous` → `events` resolves the large majority of real pod-level incidents before you touch anything.

### What each state is telling you

`describe` and `get pod` hand you a status; these are the ones worth recognising on sight:

| What you see | What it means | First move |
|--------------|---------------|------------|
| `CrashLoopBackOff` | Container starts, exits non-zero, restarts, backs off exponentially | `logs --previous` — the app told you why before it died |
| `ImagePullBackOff` / `ErrImagePull` | Can't pull the image: wrong tag, private registry, or (in kind) never loaded | `describe` events show the exact registry error; `docker exec dojo-control-plane crictl images` |
| `OOMKilled` (exit 137) | Container hit its memory limit, kernel killed it | Raise limit or fix the leak; `lastState.terminated.reason` confirms |
| `Pending` + `FailedScheduling` | Scheduler can't place it: insufficient CPU/mem, taints, node selector | `describe` events quote the exact predicate that failed |
| `Running` but not `Ready` | Readiness probe failing — gets no traffic but isn't restarting | `describe` shows probe failures; `logs` for why the endpoint 503s |
| `Terminating` stuck forever | Finalizer waiting, or a graceful shutdown that never completes | Check finalizers; `--grace-period=0 --force` as a last resort |
| `Completed` on a Deployment pod | App exited 0 on a workload meant to stay up (wrong `command`) | It's not a crash — the process returned; fix the entrypoint |

> **Exit codes are a map.** `137 = 128 + 9` (SIGKILL — OOM or a `kill`). `143 = 128 + 15` (SIGTERM — a graceful stop that the app honored). `1`/`2` are app-level errors (read the logs). A non-128 code is *your code* failing; a 128+N code is *something sent a signal*. Reading the number before the logs tells you which story you're in.

---

## Triage: stop the bleeding before you diagnose

Here is the hardest instinct to build, and the most valuable: **during an active incident, your first job is to restore service, not to understand the bug.** Diagnosis is a postmortem activity. Mitigation is a right-now activity. Conflating them is how a 5-minute outage becomes a 50-minute one while an engineer reads code.

The triage decision tree:

```
  Page fires
     │
     ▼
  Did anything change recently? ──yes──▶ ROLL IT BACK FIRST.  ◀── the default
     │                                   (deploy, config, flag, infra)
     no
     ▼
  Is it a single pod / node? ──yes──▶ cordon/drain or delete the pod;
     │                                 let the control plane reschedule
     no
     ▼
  Is a dependency down? ──yes──▶ fail over / shed load / serve degraded
     │
     no
     ▼
  Escalate + widen the net (it's not where you first looked)
```

### Rollback-first instinct

The large majority of incidents are triggered by a *change* — a deploy, a config edit, a feature flag, a dependency bump. So the highest-probability, fastest mitigation is almost always: **undo the most recent change.** Kubernetes makes this one command, and you should be able to type it without thinking:

```bash
# what just changed, and when?
kubectl -n dojo-incident rollout history deploy/web

# undo to the previous revision — the single most valuable incident command
kubectl -n dojo-incident rollout undo deploy/web

# or to a specific known-good revision
kubectl -n dojo-incident rollout undo deploy/web --to-revision=7

# confirm the rollback actually completed
kubectl -n dojo-incident rollout status deploy/web --timeout=120s
```

Rolling back a *healthy* deploy that turned out to be innocent costs you two minutes and a mild embarrassment. *Not* rolling back a bad deploy because you wanted to "understand it first" costs you your error budget and your weekend. The asymmetry is the whole argument: **when in doubt, roll back, then diagnose from the calm side.** You can always re-deploy the fix once you understand it.

> This is also why Module 01's `maxUnavailable: 0` + readiness-probe rollout discipline matters so much: a clean rollout is a *reversible* rollout. If your deploys aren't safely undo-able, you've taken your fastest mitigation off the table before the incident even started.

---

## Ephemeral debug containers — debugging what you can't shell into

The modern reality: your production image is `distroless` or `scratch`. There's no shell, no `curl`, no `ps`, nothing to `kubectl exec` into. That's correct security posture — and it used to make live debugging miserable. `kubectl debug` fixes it by attaching an **ephemeral container** that shares the target pod's namespaces (network, and optionally process) without modifying the pod spec or restarting anything.

```bash
# attach a netshoot sidecar that shares the target CONTAINER's process namespace.
# you now see the app's processes, its localhost, its network — from a fat toolbox image.
kubectl -n dojo-incident debug -it <pod> \
  --image=nicolaka/netshoot:v0.13 \
  --target=<app-container> -- bash
```

Three distinct `kubectl debug` modes, each for a different wall you've hit:

| You need to… | Command shape | Why |
|--------------|---------------|-----|
| Get tools *inside* a running pod (no shell in the image) | `kubectl debug -it <pod> --image=nicolaka/netshoot:v0.13 --target=<ctr>` | Ephemeral container shares the pod's net/process ns; non-destructive |
| Debug a pod that **crashes on start** (never stays up to exec into) | `kubectl debug <pod> -it --image=busybox:1.36 --copy-to=<pod>-dbg --container=<ctr> -- sh` | Makes a *copy* with a debug command so you can poke the filesystem/env |
| Debug at the **node** level (kubelet, container runtime, host net) | `kubectl debug node/<node> -it --image=nicolaka/netshoot:v0.13` | Lands a pod in the node's host namespaces with the host fs under `/host` |

Key property to internalise: an ephemeral container **cannot be removed** from a pod once added and **does not restart** the pod. It's a surgical, append-only, temporary addition — perfect for live incidents because it changes nothing about the running workload. When you're done, delete the pod (if it's managed, it reschedules clean) or the copy.

### netshoot — the network debugging toolbox

`nicolaka/netshoot` is the Swiss-army knife for the single most common "it's green but broken" class: **DNS and connectivity.** Pin the tag (`v0.13`), never `:latest`. The moves you'll actually make:

```bash
# throwaway debug pod on the cluster network (not attached to anything)
kubectl -n dojo-incident run netshoot --rm -it \
  --image=nicolaka/netshoot:v0.13 --restart=Never -- bash

# inside it — the connectivity checklist, in order:
nslookup web.dojo-incident.svc.cluster.local   # 1. does the Service name even resolve?
nslookup kubernetes.default                     # 2. is cluster DNS (CoreDNS) itself alive?
curl -s -o /dev/null -w '%{http_code}\n' http://web.dojo-incident.svc   # 3. does the Service answer?
curl -s -o /dev/null -w '%{http_code}\n' http://<pod-ip>:80             # 4. does the POD answer directly?
```

That 4-step ladder localises almost any "service can't reach service" fault: if (1) fails it's DNS/Service-name, if (2) fails CoreDNS is down, if (3) fails but (4) works it's the Service/Endpoints/selector, if (4) also fails it's the pod/app itself. Going straight to "it's a network issue" without walking the ladder is how teams blame the mesh for a typo in a selector.

```bash
# is the Service actually wired to any pods? empty ENDPOINTS = selector mismatch, not a network fault.
kubectl -n dojo-incident get endpoints web
kubectl -n dojo-incident get endpointslices -l kubernetes.io/service-name=web
```

---

## Dropping to the node — when kubectl isn't enough

Because kind runs every node as a container, node-level debugging is a `docker exec` away — the same skill that transfers directly to debugging a real kubelet, just without SSH. When `kubectl` itself is confused (API server flaky, a node `NotReady`), drop one level down:

```bash
# which nodes does the dojo cluster have?
kind get nodes --name dojo

# is the kubelet healthy on a node? (kubelet runs as a systemd unit INSIDE the node container)
docker exec dojo-control-plane journalctl -u kubelet --no-pager | tail -40

# what containers does the runtime actually see on this node? (bypasses the API server entirely)
docker exec dojo-control-plane crictl ps -a

# node resource pressure that the scheduler/kubelet reacts to
docker exec dojo-control-plane sh -c 'cat /proc/loadavg; head -3 /proc/meminfo'
docker stats --no-stream        # live CPU/mem per node-container
```

This is the escape hatch when the control plane is lying to you or unreachable: the runtime's view (`crictl`) is ground truth, independent of whether the API server can report it.

---

## A worked incident: the latency spike

Theory is cheap. Here's the loop run end-to-end on a real failure mode — a **latency spike driven by saturation** — so you can see the triage structure actually route you to the fix. Namespace `dojo-incident`, service `web`.

**T+0 — the page.** Module 06's fast-burn alert fires: `ErrorBudgetBurnFast on web`. p99 latency on the RED row has jumped from 40ms to 3.2s; error rate is creeping up as requests start timing out. Traffic (req/s) is normal — so this is *not* a load spike from a campaign; demand didn't change, capacity to serve it did.

**T+1 — triage first: did anything change?**

```bash
kubectl -n dojo-incident rollout history deploy/web
# REVISION 5 was 4 minutes ago — suspiciously close to T+0.
```

A change landed right before the symptom. The rollback-first instinct says: undo it now, understand later. But first a 10-second look to confirm we're not about to roll back something innocent while the real cause rages:

**T+2 — the loop, in order.**

```bash
kubectl -n dojo-incident describe pod -l app=web | sed -n '/Events:/,$p'
#   Events: nothing alarming — no FailedScheduling, no probe failures, pods Running+Ready.

kubectl -n dojo-incident logs -l app=web --tail=50
#   app logs show requests being served, just... slowly. No errors, no panics.

kubectl top pod -n dojo-incident
#   NAME            CPU(cores)   MEMORY
#   web-xxx         248m         40Mi          <-- pinned at ~250m, which is the LIMIT
```

CPU is pinned at the limit. That's the smell. The golden-signal "latency" panel feels it but can't explain it; the **saturation** signal does. Confirm throttling (the Module 06 query):

```bash
# in Prometheus: is the container being CPU-throttled?
#   rate(container_cpu_cfs_throttled_periods_total{namespace="dojo-incident",pod=~"web.*"}[5m])
#   / rate(container_cpu_cfs_periods_total{namespace="dojo-incident",pod=~"web.*"}[5m])
#   -> 0.74   (throttled 74% of CPU periods)
```

74% throttling. The new revision (rev 5) either lowered the CPU limit or added CPU-hungry work. The latency isn't a code hang — it's the kernel's CFS throttler parking the process off-CPU for three-quarters of every scheduling period. **Saturation was the leading indicator; latency and errors were the lagging symptoms the user felt.**

**T+3 — mitigate (roll back), then fix properly.**

```bash
# fastest path back to service: undo the change that correlated with T+0
kubectl -n dojo-incident rollout undo deploy/web
kubectl -n dojo-incident rollout status deploy/web --timeout=120s
# p99 drops back to ~40ms within a rollout. Bleeding stopped. Budget stops burning.
```

Service restored. *Now*, from the calm side, the real fix — rev 5 had dropped the CPU limit to `250m` for a workload that genuinely needs more headroom:

```bash
# raise the limit (and keep request:limit ratio sane to avoid throttling bursts)
kubectl -n dojo-incident set resources deploy/web \
  --requests=cpu=200m,memory=64Mi --limits=cpu=500m,memory=128Mi
kubectl -n dojo-incident rollout status deploy/web
```

**T+10 — verify the fix on the dashboard, not in your head.** p99 back to baseline, throttling query reads ~0, error rate back to zero, burn-rate alert resolved (the Module 06 short window recovers and silences it). Only now is the incident *over*.

The structure did the work: **traffic-normal-but-latency-high → it's capacity not demand → top shows CPU pinned → throttling confirms → rollback mitigates → resize fixes.** You never guessed. Each step narrowed the next.

---

## Debugging incident response itself

The meta-failures — ways the *response* goes wrong even when the bug is findable:

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| 40 minutes in, still "investigating," service still down | Diagnosing instead of mitigating — no rollback-first instinct | Mitigate first (roll back / shed load), diagnose after service is restored |
| Root cause lost forever after a restart | `kubectl delete pod` before `logs --previous` | Capture `--previous` logs and `describe` output *before* any destructive action |
| Can't debug the distroless prod pod (no shell) | Trying to `exec` into an image with no `/bin/sh` | `kubectl debug` ephemeral container with netshoot/busybox |
| "It's a network problem" but it isn't | Skipped the DNS→Service→Endpoints→pod ladder | Walk the 4-step netshoot ladder; check `get endpoints` for a selector mismatch |
| Same incident recurs a month later | No postmortem, or a blameful one that taught nothing | Blameless postmortem with owned, dated action items |
| Multiple engineers stepping on each other mid-incident | No incident commander; everyone fixing in parallel | One IC owns coordination + comms; others act only on IC's say-so |

### Diagnose the response, not just the bug

**Capture before you destroy.** The instinct to `delete pod` and "see if it comes back clean" erases evidence. Snapshot first:

```bash
kubectl -n dojo-incident logs <pod> --previous > /tmp/incident-$(date +%s)-prev.log 2>&1 || true
kubectl -n dojo-incident describe pod <pod> > /tmp/incident-$(date +%s)-describe.txt
kubectl -n dojo-incident get events --sort-by=.lastTimestamp > /tmp/incident-$(date +%s)-events.txt
# NOW you can safely delete / roll back without losing the story
```

> **War story.** At SAP, our LGTM ingest pipeline started dropping log batches — the error-budget burn alert paged at 2am. The on-call (me) saw `CrashLoopBackOff` on an ingester pod and did the natural thing: `kubectl delete pod` to "get it healthy." It came back green. Twenty minutes later it crashed again. I'd deleted the pod *before* pulling `--previous` logs, so the crash reason was gone, and I spent the next hour re-triggering the crash to catch it live. The actual cause was a poison-pill message exceeding a decode buffer — one `logs --previous` line (`panic: message too large: 12MB`) would have told me in thirty seconds. Two lessons welded in that night: **capture evidence before you mutate anything**, and the fix wasn't "restart the pod" — it was a size guard on ingest *plus* a dead-letter path so one bad message can't take the pipeline down. We rolled back the deploy that removed the old size check (mitigate), then shipped the guard (fix). The postmortem's action items — the DLQ, the buffer-size alert, the "capture-before-delete" runbook line — are why that incident happened exactly once.

---

## Blameless postmortems — closing the loop

Module 01 made the case for *why* blameless; this is the artifact and the trigger. An incident you don't learn from is one you'll have again. The postmortem converts pain into a permanent guardrail — but only if people feel safe enough to tell the truth, which means it assumes everyone acted reasonably with the information they had and asks *"what about the system let a reasonable person cause this?"* — never *"who screwed up?"*

A postmortem that's actually worth writing has:

- **A timeline** with timestamps: detection → diagnosis → mitigation → resolution. This exposes your real **MTTD** and **MTTR**, usually the biggest levers for next time.
- **Impact quantified against the SLO**: "burned 60% of the monthly error budget; ~12k users saw 503s for 18 minutes." Tie it to the Module 06 budget number so it's objective, not vibes.
- **Root cause(s), plural** — via 5-whys or a causal chain. Real incidents are never one cause; they're several guardrails failing together (the latency spike above: a bad limit *and* no limit-change alert *and* a reversible-but-not-reverted deploy).
- **Action items, each with an owner and a due date**, each a concrete change: an alert, a test, an automation, a runbook line. "Be more careful" is not an action item.

> **The trigger rule, repeated because it's the thing that makes postmortems actually happen:** decide *in advance* what automatically earns a postmortem — e.g. "any event that burns >20% of a monthly budget, any out-of-hours page, any customer-reported outage." Removing the in-the-moment judgement call ("was this big enough?") is what turns postmortems from a good intention into a habit. The action items feed straight back into the error-budget work from Module 06 — that's the reliability loop closing on itself.

---

## Checkpoint

You're ready to move on when you can, without looking anything up:

1. Run the triage loop (describe → logs → events → top) from memory and say the one question each step answers.
2. Explain why `logs --previous` is the command people skip and what it costs to skip it.
3. Read an exit code (137 vs 143 vs 1) and say what sent — or didn't send — a signal.
4. State the rollback-first instinct and the asymmetry argument that justifies it, and give the three `rollout` commands.
5. Attach an ephemeral debug container to a distroless pod, and say why `kubectl debug` doesn't restart or permanently alter the pod.
6. Walk the netshoot DNS→Service→Endpoints→pod ladder and say what a failure at each rung localises the fault to.
7. Drop to a kind node with `docker exec` to read kubelet logs and `crictl ps`, and say why the runtime's view is ground truth.
8. Narrate the worked latency incident and show how "traffic normal + latency high" routed you to saturation, not demand.
9. Name the capture-before-delete commands and explain, from the war story, why they matter.
10. List the four parts of a blameless postmortem and state why a pre-agreed trigger is what makes them happen.

➡ You've now closed the full reliability loop: set objectives (Module 01), make the service resilient and scalable, observe it and alert on budget burn (Module 06), and respond when it breaks (here). Next up are the course's incident-style challenges — where these loops stop being reading and start being timed.
