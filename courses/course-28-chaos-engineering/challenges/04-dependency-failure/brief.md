# Dependency Failure: Graceful Degradation

Your monitoring page lights up at 3 AM: the `app` Deployment is at 0/2 ready replicas. The app container itself is healthy — logs are clean, process is running. The root cause: the backend service had a brief restart 8 minutes ago, and because the app's readiness check reaches out to the backend, every probe failure propagated upward. The backend failure became an app failure became a customer-facing outage. Cascade, not containment.

You've inherited the same anti-pattern here.

## What's planted

`setup.sh` deploys two objects in namespace `dojo-chaos-dep`:

| Object | Role |
|--------|------|
| `backend` (2 replicas) | Upstream service; `nginx:1.27-alpine` on port 80 |
| `app` (2 replicas) | Frontend proxy; **misconfigured readinessProbe** that calls `backend-svc` |

Inspect the broken probe:

```bash
kubectl -n dojo-chaos-dep get deploy app \
  -o jsonpath='{.spec.template.spec.containers[0].readinessProbe}' && echo
```

The probe runs `wget` against `backend-svc` on every cycle. When backend is unavailable, wget fails, the probe fails, and the app sheds all traffic — even though the app process itself is perfectly fine.

## Mission

Fix the `app` Deployment so it degrades gracefully when the backend disappears:

1. **Decouple the readinessProbe** — it must check the app's own health, not the backend's. A simple `httpGet` on the app's own port qualifies; a dedicated `/healthz` endpoint is best practice.
2. **Add resource `requests`** (cpu + memory) on the app container — minimum Burstable QoS.
3. The verifier will inject the fault itself: it scales `backend` to 0, waits for probe cycles to run, then checks app readiness.

## What the verifier checks

```
backend Deployment: readyReplicas == 0    (fault active)
app Deployment:     readyReplicas >= 1    (graceful degradation, not crash)
```

Both conditions are checked simultaneously. If your probe still calls `backend-svc`, the app pods will go `NotReady` within ~10 seconds of the backend disappearing and the verifier will fail.

## Why the two-layer model matters

The `readinessProbe` answers exactly one question: *"is this pod ready to receive traffic right now?"* The answer should come from the pod itself — not from a downstream call. Downstream calls in probes create three failure modes:

| Failure mode | Cause | Consequence |
|---|---|---|
| Cascade NotReady | Downstream is unavailable | Healthy app sheds all traffic |
| Slow probe cycles | Downstream is slow | Probe timeouts eat into `periodSeconds`, causing spurious failures |
| Thundering herd | All app pods probe backend simultaneously | N app pods × probe frequency = unexpected backend load |

The right architecture is two layers:

**Layer 1 (Kubernetes level):** `readinessProbe` checks only the pod's own process health — a `/healthz` that returns 200 as long as nginx is accepting connections. k8s uses this for traffic routing decisions.

**Layer 2 (application level):** nginx handles backend unavailability — `proxy_connect_timeout`, `proxy_read_timeout`, and `error_page 502 503 504` to serve a fallback. The app *degrades* (serves a fallback or cached response) rather than refusing to accept traffic at all.

The verify checks layer 1. The solution shows both layers.

## Prerequisites

- Docker + kind cluster running (`kubectl config current-context` → `kind-dojo`)
