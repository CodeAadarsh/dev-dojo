# Chaos Engineering Principles

> **Module 01 · Course 28** — Chaos engineering is not "break things and hope for the best." It is a disciplined experimental method that builds *measurable confidence* in a system's resilience before an incident proves you were wrong. This module is the mental model; the rest of the course is the toolbox.

You already run Kubernetes at work. You've had pages. You've fixed things under pressure. This module reframes that reactive loop into something you can front-run: *cause* the failure on your own terms, while you're alert and can abort.

---

## What chaos engineering actually is

Netflix coined the phrase in 2011 after their AWS migration left them with a question they couldn't answer from code review alone: "Does this actually hold up when a region goes away?" They couldn't prove it without testing it. Chaos engineering is that proof process.

The [Principles of Chaos Engineering](https://principlesofchaos.org/) definition is precise:

> *Chaos Engineering is the discipline of experimenting on a system in order to build confidence in the system's capability to withstand turbulent conditions in production.*

Three words matter:
- **Discipline** — not random, not reckless; there is a method
- **Experimenting** — hypothesis, inject, measure, conclude; this is science
- **Confidence** — the output is a measured belief, not a binary "it worked"

Chaos engineering is not:
- Randomly deleting pods to see what happens (that's chaos theater)
- A one-time test that goes in a report and is never repeated
- A substitute for good design — it *validates* design decisions and surfaces gaps

---

## The scientific-experiment framing

Every chaos experiment follows the same structure, every time:

```
1. Define the steady state (what does "normal" look like, quantified)
2. Form a hypothesis: "steady state will hold under fault X"
3. Inject fault X with a controlled blast radius
4. Measure: did steady state hold?
5. Conclude: confidence increases if yes; you found a real gap if no
```

This structure is not optional. Without it you are testing a story you already believe, not falsifying a hypothesis.

```
┌────────────────────────────────────────────────────────────────────────┐
│                    Chaos Experiment Lifecycle                          │
│                                                                        │
│  ┌──────────────┐   define    ┌──────────────────────┐                │
│  │ Steady-State │ ──────────▶ │     Hypothesis        │               │
│  │  (metrics)   │             │ "SLO holds under      │               │
│  └──────────────┘             │  pod eviction"        │               │
│                               └──────────┬────────────┘               │
│                                          │ inject                     │
│                               ┌──────────▼────────────┐               │
│                               │    Fault Injection     │              │
│                               │  (controlled scope)    │              │
│                               └──────────┬────────────┘               │
│                                          │ measure                    │
│                               ┌──────────▼────────────┐               │
│                               │   Observe & Log        │              │
│                               └──────────┬────────────┘               │
│                                          │ conclude                   │
│                               ┌──────────▼────────────┐               │
│                               │ Confidence ↑ / Gap ↓   │             │
│                               └────────────────────────┘              │
└────────────────────────────────────────────────────────────────────────┘
```

---

## Steady-state hypothesis

The steady state is the observable, *quantified* normal behavior of your system before the experiment. It is the baseline you compare against while the fault is active and after it clears.

A steady-state hypothesis has two parts:
1. **A measurable signal**: error rate < 0.1%, p99 latency < 500ms, ready replica count >= 2
2. **A direction**: "this signal will still satisfy its bound while the fault is active AND after it clears"

Bad hypothesis (untestable): *"The system will handle pod failures gracefully."*

Good hypothesis (measurable): *"Under continuous pod deletion of the `payments` Deployment at one pod per 30 seconds, HTTP 5xx rate as seen from the load balancer stays below 0.5%, and drops back to 0 within 60s of stopping the injection."*

The signal must be **external** — measured from the perspective of a client, not just Kubernetes control-plane events. "Deployment shows 3/3 Ready" is not a steady state; "load balancer serves < 0.5% HTTP errors" is.

Practical tools to instrument steady-state without a full observability stack:

```bash
# Continuous HTTP error rate check during the experiment:
while true; do
  code=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/healthz)
  echo "$(date +%T) $code"
  sleep 1
done

# Use wrk for a 2-minute load baseline before injection:
wrk -t4 -c40 -d120s --latency http://localhost:8080/

# Prometheus instant query if you have it (from outside the cluster):
kubectl exec -n monitoring deploy/prometheus -- \
  promtool query instant 'rate(http_requests_total{status=~"5.."}[1m])'
```

---

## Blast-radius control

Blast radius = the maximum possible scope of impact from the experiment.

The tightest blast radius you can have while still learning something useful is the right blast radius. That means:

| Control lever | How to shrink the blast radius |
|--------------|-------------------------------|
| **Scope** | Target one namespace, one deployment, one pod — not the whole cluster |
| **Traffic** | Route only a small slice of production traffic through the experiment |
| **Timing** | Run during low-traffic windows; never during deployments or on-call escalation |
| **Duration** | Cap experiment duration; auto-stop if steady state breaks |
| **Rollback** | Have a one-command abort that restores pre-experiment state, written down before you start |

In kind clusters, blast radius is per-namespace. Every experiment in this dojo targets `dojo-chaos-*` namespaces. The rest of the cluster is irrelevant — that's the dojo's version of blast-radius control, and it mirrors the "scope to one service" strategy in prod.

---

## Prod vs staging

The canonical chaos engineering position is that **production is the only fully valid target**, because staging environments systematically differ in ways that matter:

- Different traffic patterns — no real users means caches hit differently and hot paths don't get hit
- Fewer replicas — "1 pod deleted" can be a 50% capacity loss in staging and a 10% loss in prod
- Mocked dependencies — the actual third-party timeout behavior doesn't appear
- Different network topology — inter-zone latency doesn't manifest on a single-node staging cluster

That said, staging experiments are not useless — they are warm-up runs. You catch misconfigured experiments, missing permissions, and "the abort command doesn't work" issues before running in prod.

The pragmatic ramp for a team starting out:
1. Run in staging first to validate the experiment mechanics are correct
2. Run in prod with a minimal blast radius (1 pod, 5 minutes) and someone watching dashboards
3. Expand duration and scope as confidence in the *experiment tooling* grows

At regulated enterprises (SAP, BFSI), "prod chaos" is typically a change ticket with a rollback plan, a maintenance window, and an on-call engineer on a bridge. The experiment is the change.

---

## Minimize-blast and abort conditions

The minimize-blast principle: start with the smallest fault that tests your hypothesis and expand only after confirming the experiment behaves as expected.

An abort condition is a predicate you define *before* starting that automatically stops the experiment if things go sideways faster than expected.

Hard abort conditions (stop immediately, no judgment required):
- The steady-state metric breaks its bound before the fault has finished propagating (the system was already degraded, or the hypothesis was wrong)
- A service that was explicitly *not* in scope starts degrading (blast radius leaked)
- Automated alerting fires on something unrelated to the experiment

Soft abort conditions (investigate before deciding):
- Recovery is slower than the SLO window allows
- Error rate is trending up rather than plateauing at the expected level

Write the abort command down *before* you inject:

```bash
# For kubectl-based faults (pod deletions, label changes):
kubectl rollout undo deploy/web -n dojo-chaos-pod

# For tc netem (network chaos on a kind node):
docker exec dojo-worker tc qdisc del dev eth0 root

# For iptables drops:
docker exec dojo-worker iptables -F OUTPUT

# For Chaos Mesh experiments:
kubectl patch chaosengine <name> -n dojo-chaos-net -p '{"spec":{"engineState":"stop"}}' --type=merge
```

Keep the abort command visible on your screen. The cost of running it when you didn't need to is near-zero. The cost of not having it ready when you do is measured in SLO budget.

---

## Debugging chaos experiments

### When experiments have no hypothesis

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Team runs experiment, concludes "it worked," but can't articulate what was measured | No steady-state metric defined before injection | Define a concrete Prometheus query or curl loop *before* starting; run it for 5 min pre-injection to establish the baseline |
| Post-experiment review finds the SLO was breached, but no one noticed during the experiment | Monitoring was not actively watching the right signal | Instrument the steady-state signal as a separate terminal window before starting; assign one person to watch it and do nothing else |
| Two experiments on the same system produce contradictory results | No experiment isolation; residual state from the first experiment affected the second | Wait for full recovery (all pods Ready, metrics at baseline) before starting the next experiment; use separate namespaces |
| Experiment "passed" in staging but revealed a real gap in prod | Staging difference invalidated the experiment | Note which assumption broke; document the prod-only experiment; staging is warmup, not proof |

### When blast radius is uncontrolled

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Fault injection took down a service not in scope | A shared dependency (database, DNS, distributed lock) sat inside the blast radius | Map all shared dependencies before injecting: `kubectl get networkpolicies -A`, trace upstreams of the target |
| Pod deletion in namespace A cascaded to namespace B | Shared PVC, cluster-scoped lock, or service discovery via a shared resource | Audit resource sharing; never share cluster-scoped resources between experimental and stable workloads |
| Node-level fault (tc, iptables) hit pods not in scope | All pods on that node are affected by node-level commands | Run `kubectl get pods --all-namespaces -o wide \| grep <node-name>` before touching any node; if unexpected pods are present, either accept them in the blast radius or choose a different node |

> **War story.** At a team GameDay, we injected 200ms latency on the checkout service's egress using `tc netem` on the node — checkout circuit-breaker opened cleanly, exactly as expected. What we had not mapped: the same node was running our session-token Redis replica. The 200ms added to every Redis replication write turned into replication lag, which triggered Sentinel to detect a stale replica and promote a second leader. For 90 seconds we had two Redis leaders accepting writes. The checkout team got a clean pass; the auth team got paged. The lesson: `tc` is node-global — blast radius is defined by the network interface, not the namespace. Map every pod on every target node with `kubectl get pods --all-namespaces -o wide` before you touch a node, every time.

---

## Checkpoint

You're ready for fault injection when you can, without looking anything up:

1. State the difference between a chaos experiment and randomly deleting pods.
2. Write a measurable steady-state hypothesis for a service you own, with a specific metric and numeric bound.
3. List three control levers that shrink blast radius and give one reason each matters in production.
4. Explain why staging experiments are warm-up runs rather than proof.
5. Name two hard abort conditions and write the abort command for a `tc netem` fault on a kind worker node.
6. Describe the experiment lifecycle in five steps from memory.
7. Explain what "the signal must be external" means for a steady-state hypothesis.
8. Why is a hypothesis that says "the system will handle it gracefully" insufficient for a chaos experiment?

➡ Next up: **Failure Modes & the Fault Model** — before you inject, you need to know what category of failure you're modeling, because the cure for a crash fault is not the cure for a timing fault.
