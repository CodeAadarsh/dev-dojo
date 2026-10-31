# Solution — Probe the Depths

One patch adds both probes to the container. Write the manifest (or `kubectl edit deploy web -n dojo-probes`) and apply.

```yaml
# web-probes.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: dojo-probes
  labels:
    app: web
spec:
  replicas: 2
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
        - name: web
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
          readinessProbe:            # gate traffic: only receive requests once / answers
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 2
            periodSeconds: 5
            failureThreshold: 3
          livenessProbe:             # restart only a genuinely wedged process
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 10  # generous: let the app start before we judge it alive
            periodSeconds: 10
            timeoutSeconds: 2
            failureThreshold: 3
```

Apply and verify:

```bash
kubectl apply -f web-probes.yaml
kubectl -n dojo-probes rollout status deploy/web
bash courses/course-01-ops-security/challenges/03-probe-the-depths/verify.sh
```

## Why each setting is what it is

- **Readiness is tight, liveness is forgiving.** The readiness probe can poll fast with a short `initialDelaySeconds` — the worst it does is briefly hold traffic. The liveness probe is the dangerous one: every failure budget it burns ends in a `SIGTERM`. Give it a longer `initialDelaySeconds` and a sane `failureThreshold` so a slow start or a transient blip never gets mistaken for "wedged."
- **`failureThreshold` × `periodSeconds` is your real tolerance.** With `periodSeconds: 10` and `failureThreshold: 3`, a container must fail for ~30s straight before liveness restarts it. Set `failureThreshold: 1` with a 1s period and a single GC pause will murder a healthy pod.
- **Same path, different purpose.** Both probes hit `/` here because nginx's root is a cheap, dependency-free liveness signal. In a real app, readiness should check "can I serve?" (DB reachable, caches warm) while liveness should check only "is my own event loop alive?" — never make liveness depend on a downstream, or one DB blip restarts your entire fleet.

## The crashloop you were avoiding

If you'd set the liveness probe like this:

```yaml
          livenessProbe:
            httpGet:
              path: /healthz      # nginx returns 404 here — not 2xx/3xx
              port: 80
            initialDelaySeconds: 0
            failureThreshold: 1
```

…nginx would return `404` on `/healthz`, the probe would count that as a failure, and with `failureThreshold: 1` the kubelet would kill the container almost immediately — over and over, forever. `kubectl -n dojo-probes describe pod` would show `Liveness probe failed: HTTP probe failed with statuscode: 404` followed by `Killing`, and the verifier's `readyReplicas` check would never pass. That is the single most common self-inflicted `CrashLoopBackOff`: a liveness probe pointed at a path the app doesn't actually serve 2xx on.

## Hardening preview

A third probe, the **`startupProbe`**, exists precisely to decouple "slow to boot" from "wedged at runtime." For an app with a long cold start, give it a generous `startupProbe` (e.g. `failureThreshold: 30`, `periodSeconds: 10` = 5 minutes to come up); the liveness probe is suspended until the startup probe first succeeds, after which liveness can be aggressive without risking the boot window.
