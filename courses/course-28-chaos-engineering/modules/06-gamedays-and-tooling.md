# GameDays & Experiment Tooling

> **Module 06 · Course 28** — Chaos engineering without a structured hypothesis is just breaking things and hoping you learn something useful. A GameDay is a planned, time-boxed experiment with a written hypothesis, a defined blast radius, an abort condition agreed before you start, and required action items that change what ships next sprint. The discipline is in the process, not the tool.

You've seen what individual failure modes look like. This module covers how to run them deliberately, safely, and repeatably — including inside CI pipelines.

---

## What a GameDay Is (and Isn't)

A GameDay is NOT:
- A surprise fire drill designed to stress the on-call engineer.
- Breaking production at 2 AM "to build resilience muscle."
- A free-form session of "let's see what breaks."

A GameDay IS:
- A **hypothesis-driven experiment**: *"We believe the API gateway will continue serving requests at p99 < 500ms if one of three downstream pods fails, because we have retries configured with jitter."*
- Run against a **known steady state**: SLIs are measured before injection, providing the baseline.
- **Scoped**: the blast radius is defined and limited to a specific namespace, service, or dependency.
- **Documented**: hypothesis → method → observations → action items. Every surprise is a ticket.

> **The hypothesis format.** Write it in this form: *"We believe [system] will [do X] when [fault] because [mechanism]. We will measure [SLI]. We will abort if [condition]."* If you can't write the hypothesis in one sentence, you don't understand the experiment well enough to run it yet.

---

## The GameDay Lifecycle

```
1. PLAN          Scope, team (facilitator, observers, engineers), time window,
                 rollback procedure, stakeholder notifications.

2. STEADY STATE  Measure your SLIs before touching anything.
                 Record baseline values for the metrics you'll compare against.

3. HYPOTHESIS    "If X fails, system Y continues at SLI Z because mechanism W."
                 Write it down. One sentence.

4. BLAST RADIUS  Define the exact injection: which CRs, which pods, which namespaces.
                 Label-selector dry-run before applying any chaos.

5. ABORT         The abort condition — write it now, not during the drill.
                 "If error rate > 5% on any customer-facing endpoint for > 60s,
                 delete all chaos CRs and page the on-call."
                 Automate this if at all possible.

6. RUN           Apply the chaos CR. Observe. Do NOT fix anything you see —
                 you are measuring, not firefighting. Document everything.

7. ANALYZE       Did the system behave as hypothesised? Where did it surprise you?
                 Compute recovery time as a first-class metric.

8. LEARNINGS     Required output: tickets for every surprise, runbook updates,
                 new alert rules, config changes. No action items = wasted GameDay.
```

Recovery time is a metric, not just a qualitative note. If your service takes 3 minutes to recover from a single pod kill, that's the number in the post-GameDay document — and it's the target to beat after hardening.

---

## Chaos Mesh — PodChaos and NetworkChaos

Chaos Mesh is a Kubernetes-native chaos platform. Experiments are Kubernetes Custom Resources — apply them with `kubectl`, pause them with an annotation, delete them to stop.

### Install (prereq: Helm 3, kind cluster running)

```bash
helm repo add chaos-mesh https://charts.chaos-mesh.org
helm repo update
helm install chaos-mesh chaos-mesh/chaos-mesh \
  --namespace=chaos-mesh \
  --create-namespace \
  --version 2.6.3 \
  --set chaosDaemon.runtime=containerd \
  --set chaosDaemon.socketPath=/run/containerd/containerd.sock

kubectl -n chaos-mesh get pods
# Expect: chaos-controller-manager, chaos-daemon (DaemonSet), chaos-dashboard
```

### PodChaos

```yaml
# Kill one pod from the 'web' Deployment every 2 minutes for 10 minutes.
# ALWAYS scope to an explicit namespace list.
apiVersion: chaos-mesh.org/v1alpha1
kind: PodChaos
metadata:
  name: web-pod-kill
  namespace: dojo-chaos
spec:
  action: pod-kill          # pod-kill | pod-failure | container-kill
  mode: one                 # one | all | fixed | fixed-percent | random-max-percent
  selector:
    namespaces:
      - dojo-chaos           # REQUIRED: never omit namespace scoping
    labelSelectors:
      app: web
  scheduler:
    cron: "@every 2m"
  duration: "10m"
```

The three `action` values do different things:
- `pod-kill` — deletes the pod; ReplicaSet reschedules. Tests recovery speed and persistence of in-flight requests.
- `pod-failure` — injects a condition that causes the pod to fail its probes and be excluded from traffic, without killing it. Tests readinessProbe and traffic exclusion.
- `container-kill` — kills a specific named container in a multi-container pod. Tests sidecar restart independence.

```bash
kubectl apply -f web-pod-kill.yaml

# Watch the Deployment recover:
kubectl -n dojo-chaos get pods -w

# Pause the experiment without deleting it:
kubectl annotate podchaos web-pod-kill \
  experiment.chaos-mesh.org/pause=true

# Resume:
kubectl annotate podchaos web-pod-kill \
  experiment.chaos-mesh.org/pause-  # remove the annotation

# Stop:
kubectl delete podchaos web-pod-kill
```

### NetworkChaos

```yaml
# Add 200ms ± 50ms of network delay to all outbound traffic from web pods.
apiVersion: chaos-mesh.org/v1alpha1
kind: NetworkChaos
metadata:
  name: web-latency-inject
  namespace: dojo-chaos
spec:
  action: delay
  mode: all
  selector:
    namespaces:
      - dojo-chaos
    labelSelectors:
      app: web
  delay:
    latency: "200ms"
    correlation: "25"       # % correlation between successive packets
    jitter: "50ms"
  direction: to             # to | from | both
  duration: "5m"
```

```yaml
# 30% packet loss — tests retry logic and client timeout handling.
apiVersion: chaos-mesh.org/v1alpha1
kind: NetworkChaos
metadata:
  name: web-packet-loss
  namespace: dojo-chaos
spec:
  action: loss
  mode: all
  selector:
    namespaces:
      - dojo-chaos
    labelSelectors:
      app: web
  loss:
    loss: "30"
    correlation: "25"
  direction: to
  duration: "5m"
```

```yaml
# Network partition: web pods can't reach db pods at all.
apiVersion: chaos-mesh.org/v1alpha1
kind: NetworkChaos
metadata:
  name: web-db-partition
  namespace: dojo-chaos
spec:
  action: partition
  mode: all
  selector:
    namespaces:
      - dojo-chaos
    labelSelectors:
      app: web
  direction: to
  target:
    mode: all
    selector:
      namespaces:
        - dojo-chaos
      labelSelectors:
        app: db
  duration: "2m"
```

> **Dry-run your selector before applying.** Before any chaos CR, confirm the label selector matches exactly the pods you intend: `kubectl get pods -n dojo-chaos -l app=web`. A selector that matches an unexpected pod in an unexpected namespace can take down something real. This is a non-negotiable pre-flight check.

---

## Litmus — ChaosEngine and ChaosExperiment

LitmusChaos takes a catalog approach: pre-built ChaosExperiment resources define fault profiles, and a ChaosEngine binds them to a target app.

```bash
kubectl apply -f https://litmuschaos.github.io/litmus/litmus-operator-v3.4.0.yaml
# Wait for the operator to start:
kubectl -n litmus get pods -w
```

```yaml
# ChaosEngine: run pod-delete against the 'web' Deployment.
apiVersion: litmuschaos.io/v1alpha1
kind: ChaosEngine
metadata:
  name: web-chaos
  namespace: dojo-chaos
spec:
  appinfo:
    appns: dojo-chaos
    applabel: app=web
    appkind: deployment
  engineState: active            # active | stop
  chaosServiceAccount: litmus-admin
  experiments:
    - name: pod-delete
      spec:
        components:
          env:
            - name: TOTAL_CHAOS_DURATION
              value: "60"        # seconds the experiment runs
            - name: CHAOS_INTERVAL
              value: "10"        # seconds between kills
            - name: FORCE
              value: "false"     # graceful delete; 'true' = immediate
```

```bash
# Watch the experiment lifecycle:
kubectl -n dojo-chaos get chaosengine web-chaos \
  -o jsonpath='{.status.engineStatus}{"\n"}'
# initialized → running → completed

# Read the result:
kubectl -n dojo-chaos describe chaosresult web-chaos-pod-delete
# Look for: verdict: Pass / Fail, probeSuccessPercentage
```

---

## Scheduling Experiments and CI Automation

### Scheduled GameDay experiments

Chaos Mesh supports cron scheduling inline in the CR:

```yaml
spec:
  scheduler:
    cron: "0 10 * * 2"       # every Tuesday at 10 AM
  duration: "15m"
```

Running scheduled experiments during business hours (not 3 AM) is intentional — it keeps humans in the loop and tests the on-call escalation path.

### CI integration pattern

The pattern is: apply → wait for at least one chaos cycle → assert steady state → tear down.

```bash
#!/usr/bin/env bash
# chaos-ci.sh — run in a dedicated ephemeral namespace, never shared clusters
set -euo pipefail

NS=dojo-chaos-ci
DEPLOY=web
CHAOS_CR=chaos/web-pod-kill.yaml

# Scope check — refuse to run outside an isolated CI namespace
CURRENT_CTX=$(kubectl config current-context)
if ! echo "$CURRENT_CTX" | grep -q "kind-"; then
  echo "ABORT: not targeting a kind cluster. Context: $CURRENT_CTX"
  exit 1
fi

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

# Deploy the target service
kubectl -n "$NS" apply -f manifests/web.yaml
kubectl -n "$NS" rollout status deploy/"$DEPLOY" --timeout=120s

# Apply chaos
kubectl -n "$NS" apply -f "$CHAOS_CR"

# Wait for two kill cycles (2m interval × 2 = 4m + buffer)
sleep 260

# Assert: all replicas recovered
READY=$(kubectl -n "$NS" get deploy "$DEPLOY" \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
DESIRED=$(kubectl -n "$NS" get deploy "$DEPLOY" \
  -o jsonpath='{.spec.replicas}')

if [ "${READY}" != "${DESIRED}" ]; then
  echo "FAIL: only ${READY}/${DESIRED} replicas ready after chaos"
  kubectl -n "$NS" get pods
  kubectl delete -f "$CHAOS_CR" --ignore-not-found=true
  exit 1
fi

echo "PASS: ${READY}/${DESIRED} replicas ready after pod-kill chaos"
kubectl delete -f "$CHAOS_CR" --ignore-not-found=true
```

> **CI scoping rules.** Never run network-partition chaos against a shared namespace on a shared cluster — blast radius is unpredictable. CI chaos targets a dedicated ephemeral namespace, and the label selectors in every chaos CR include that namespace explicitly. Use a `kind` cluster per CI job for full isolation. The check for `kind-` in the context name is a lightweight guard against accidentally running chaos on a real cluster from CI.

---

## The Experiment Lifecycle

```
┌──────────────────────────────────────────────────────────────┐
│  STEADY STATE VERIFICATION                                    │
│  Measure SLIs. Record: error rate, p99 latency, pod count.   │
│  This is your pre-chaos baseline. Do not skip this step.     │
└────────────────────────┬─────────────────────────────────────┘
                         │
┌────────────────────────▼─────────────────────────────────────┐
│  FAULT INJECTION                                              │
│  Apply chaos CR. Note the exact timestamp.                   │
│  Confirm the chaos daemon is actually injecting (see logs).  │
└────────────────────────┬─────────────────────────────────────┘
                         │   ← abort condition fires here if SLI breached
┌────────────────────────▼─────────────────────────────────────┐
│  OBSERVATION WINDOW                                           │
│  Measure SLIs during fault. Do not intervene to fix things.  │
│  Document every observation, including surprises.            │
└────────────────────────┬─────────────────────────────────────┘
                         │
┌────────────────────────▼─────────────────────────────────────┐
│  RECOVERY                                                     │
│  Delete/pause chaos CR. Note the timestamp.                  │
│  Measure time-to-recovery: from injection to steady state.   │
└────────────────────────┬─────────────────────────────────────┘
                         │
┌────────────────────────▼─────────────────────────────────────┐
│  ANALYSIS & ACTION ITEMS                                      │
│  Did the hypothesis hold?                                     │
│  File a ticket for every surprise. No exceptions.            │
│  Update runbooks. Add alert rules if blind spots found.      │
└──────────────────────────────────────────────────────────────┘
```

The two numbers that go into every post-GameDay report: **p99 latency during fault** vs baseline, and **mean time to recovery (MTTR)**. If you don't measure both, you didn't run an experiment — you ran a drill.

---

## Debugging GameDays

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Chaos Mesh CR applied but no pods killed | Chaos daemon not on that node (`chaosDaemon` DaemonSet not running) | `kubectl -n chaos-mesh get pods -o wide`; verify daemon is on the same node |
| PodChaos shows `Running` but selector matches nothing | Label selector is wrong or scoped to the wrong namespace | `kubectl get pods -n dojo-chaos -l app=web` to dry-run the selector |
| NetworkChaos applied but no latency observed | tc (traffic control) binary missing from node OS, or daemon not injecting | `kubectl -n chaos-mesh logs ds/chaos-daemon`; check for tc errors |
| ChaosEngine stays `initialized`, never transitions to `running` | RBAC — ChaosServiceAccount lacks `pods/exec` or `chaos` permissions | `kubectl describe chaosengine`; inspect ServiceAccount bindings |
| Chaos ran, SLI alert never fired | Alert threshold too conservative, or Prometheus scrape interval too coarse | Verify alert expression in Prometheus UI; reduce `scrape_interval` for the target during drills |
| Experiment took down production | Blast radius not scoped; selector matched pods outside test namespace | Add explicit namespace list to every chaos selector; verify with dry-run first |
| Abort condition triggered but chaos kept running for 3 more minutes | Abort condition was manual — human reaction time was too slow | Automate the abort: a watchdog script that `kubectl delete`s chaos CRs when the SLI SLO breaches |
| Post-GameDay has no action items | No tickets filed during analysis; "we'll do it later" | Action items are required output, not optional follow-up. File during the analysis step. |

> **War story.** We ran a GameDay to validate that our API tier could survive a 50% pod kill in staging. The experiment targeted `app=api` in `namespace=staging`. What we missed: staging shared a node pool with a prod-adjacent canary namespace, and someone had labelled a canary pod `app=api` without the namespace scoping we assumed would be there by default. Chaos Mesh's `namespaces: []` default means *all namespaces* — it matched the canary. The `pod-kill` fired on both staging and the canary simultaneously. The canary had no PDB; 2 of 2 replicas were killed. The canary went down for 4 minutes before the ReplicaSet recovered it. Customers on the canary cohort saw errors. The abort condition we'd defined — "error rate > 1% on production" — would have caught it if we'd automated the rollback. We hadn't; the human noticed after the impact window closed. Two things shipped the following sprint: explicit `namespaces:` lists on every chaos CR in every environment, and an automated watchdog that runs every 30 seconds during any active experiment and `kubectl delete`s the chaos CR if the production error SLO is breached. The blast radius mistake was mine. The absent automation made it a customer incident instead of just an embarrassing near-miss.

---

## Checkpoint

You're ready for the challenges when you can, without looking anything up:

1. Write a four-step GameDay plan for validating that your service survives a single-AZ node loss, including the hypothesis and the abort condition.
2. Author a `PodChaos` CR that kills one pod from a Deployment named `api` every 5 minutes for 15 minutes, scoped explicitly to namespace `dojo-chaos`.
3. Author a `NetworkChaos` CR that injects 150ms ± 30ms of latency on inbound traffic to pods labelled `app=db` in `dojo-chaos`.
4. Explain the difference between Chaos Mesh's `pod-kill` and `pod-failure` actions and name a scenario where you'd choose each.
5. Write the CI integration shell script: apply chaos → wait → assert ready replicas match desired → tear down.
6. State the single thing that makes an abort condition useful vs useless (hint: when you write it matters as much as what it says).
7. Diagnose why a `NetworkChaos` CR shows status `Running` but no latency appears in your service's traces.
8. Name the two production mistakes in the war story and the specific controls that prevent each.

➡ Next up: **Building Resilience** — the patterns chaos engineering is actually validating: timeouts, retries, circuit breakers, bulkheads, and graceful degradation.
