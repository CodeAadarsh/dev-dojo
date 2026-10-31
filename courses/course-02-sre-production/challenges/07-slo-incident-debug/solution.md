# Solution — Page at 3am

## Root cause

The container is healthy. nginx is listening on **port 80** and serving `/` with a `200`. But the `readinessProbe` is configured to `httpGet` on **port 8080** — a port nothing is listening on. So every probe attempt gets `connection refused`, the pod never flips to `Ready`, and because the endpoint controller only adds *Ready* pods to a Service's endpoints, the `web` Service ends up with **zero backends**. Green deploy, clean logs, dark service.

This is one of the most common real incidents there is: a readiness probe that points at the wrong **port** (or path, or scheme) after a config change, a copy-paste, or a container that moved its listener. The deploy "succeeds" from the Deployment controller's point of view (pods are scheduled and Running), monitoring on container restarts stays silent (nothing is crashing), and the only signal is the gap between `Running` and `Ready`.

## How you'd find it (the triage, end to end)

```bash
# 1 & 2: deploy green-ish but 0 Available; pods Running but 0/1 Ready
kubectl -n dojo-incident get deploy web
kubectl -n dojo-incident get pods -l app=web

# 3: the smoking gun is in describe's Events at the bottom
kubectl -n dojo-incident describe pod -l app=web | sed -n '/Conditions:/,$p'
#   Warning  Unhealthy  ...  Readiness probe failed: Get "http://10.244.x.y:8080/":
#                            dial tcp 10.244.x.y:8080: connect: connection refused

# 4: logs are clean -> the app is fine; the PROBE disagrees with reality
kubectl -n dojo-incident logs -l app=web --tail=20

# 5: the downstream effect — Service has no endpoints
kubectl -n dojo-incident get endpoints web
#   NAME   ENDPOINTS   AGE
#   web    <none>      7m

# confirm what port the container actually serves on
kubectl -n dojo-incident get deploy web -o jsonpath='{.spec.template.spec.containers[0].ports[*].containerPort}{"\n"}'   # 80
kubectl -n dojo-incident get deploy web -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.port}{"\n"}' # 8080  <-- mismatch
```

The `connection refused` on `:8080` next to a `containerPort: 80` is the entire diagnosis: the probe and the app disagree about the port.

## The fix

Point the readiness probe at the port the container actually serves on (`80`):

```bash
kubectl -n dojo-incident patch deploy web --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/port","value":80}]'
```

Or `kubectl -n dojo-incident edit deploy web` and change the probe port from `8080` to `80`. Declarative equivalent:

```yaml
# the corrected probe block in the Deployment's container spec
readinessProbe:
  httpGet:
    path: /
    port: 80          # was 8080 — now matches the containerPort nginx listens on
  initialDelaySeconds: 2
  periodSeconds: 5
  failureThreshold: 3
```

Watch it recover, then verify:

```bash
kubectl -n dojo-incident rollout status deploy/web
kubectl -n dojo-incident get pods -l app=web          # now 1/1 Ready across the board
kubectl -n dojo-incident get endpoints web            # now lists 3 pod IPs
bash courses/course-02-sre-production/challenges/07-slo-incident-debug/verify.sh
```

## Why this incident is sneaky (and how to not get paged by it again)

- **`Running` is not `Ready`.** Alerting on pod restarts or `CrashLoopBackOff` would never have caught this — nothing crashed. The only early signal was `AVAILABLE < desired` on the Deployment and empty `endpoints` on the Service. Alert on **readiness** (`kube_deployment_status_replicas_available` vs `_replicas`, or endpoint count), not just on crashes.
- **A readiness probe that can never pass turns a rollout into a silent outage.** With a rolling update, new pods never go Ready, so the rollout *stalls* rather than fails loudly — and if you had no prior healthy ReplicaSet (a fresh deploy, as here), you go straight to zero capacity. Always watch `kubectl rollout status` on deploys and give it a `--timeout` in CI so a stuck roll fails the pipeline instead of your SLO.
- **Probe config is an integration contract with the app.** The three classic mismatches are **port** (this one), **path** (`/` vs `/healthz`), and **scheme** (`HTTP` probe against an HTTPS listener). When you change any of those in the app, the probe has to change in lockstep.
- **Readiness vs liveness matters here.** A *liveness* probe on the wrong port would be far worse: it would keep **killing and restarting** the healthy container (`CrashLoopBackOff` with a clean app), amplifying the incident. A readiness mismatch "only" removes the pod from rotation. Know which probe you're touching before you touch it.

## SRE framing — what the drill actually trained

You practiced reading **cluster state as a causal chain**, not a status page: `Deployment AVAILABLE=0` → `pods Running but 0/1 Ready` → `describe` names the failing probe → `logs` clear the app → `endpoints empty` explains the user-facing 503s. That ladder — deploy → pod → describe/events → logs → endpoints — resolves the large majority of "service is down but nothing's crashing" pages. The skill isn't memorizing that readiness probes have ports; it's refusing to guess and letting each layer of Kubernetes state tell you exactly where reality and intent diverged.
