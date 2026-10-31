# Solution — The CrashLoop Mystery

## Root cause

The container is a **fail-fast** process: on startup it checks for `DATABASE_URL` and `exit 1`s if it's missing. The planted Deployment never sets that env var, so every start dies immediately and the kubelet restarts it with exponential backoff — the textbook `CrashLoopBackOff`.

## Diagnose it the way you would at work

```bash
# 1) Lifecycle + events. Note "Last State: Terminated, Exit Code: 1" and the BackOff events.
kubectl -n dojo-crash describe pod -l app=api | sed -n '/State:/,$p'

# 2) The crashed instance's own output — THIS is the answer.
POD=$(kubectl -n dojo-crash get pod -l app=api -o jsonpath='{.items[0].metadata.name}')
kubectl -n dojo-crash logs "$POD" --previous
# -> FATAL: DATABASE_URL is required but was not set; refusing to start

# 3) If a log is ever empty, fall back to cluster events.
kubectl -n dojo-crash get events --sort-by=.lastTimestamp | tail
```

Exit code `1` + a clear FATAL line in `--previous` = the app rejected its own config. No image problem, no OOM, no probe. Fix the config.

## The fix

Set the missing env var. Imperative is fastest — it patches the pod template and triggers a clean rollout:

```bash
kubectl -n dojo-crash set env deploy/api \
  DATABASE_URL="postgres://db.dojo-crash.svc:5432/app"

kubectl -n dojo-crash rollout status deploy/api
```

Or declaratively, add it to the container spec:

```yaml
    spec:
      containers:
        - name: api
          image: busybox:1.36
          env:
            - name: DATABASE_URL
              value: postgres://db.dojo-crash.svc:5432/app
          command: ["/bin/sh", "-c"]
          args:
            - |
              if [ -z "${DATABASE_URL:-}" ]; then
                echo "FATAL: DATABASE_URL is required but was not set; refusing to start" >&2
                exit 1
              fi
              echo "api: connected to ${DATABASE_URL}, serving on :8080"
              exec sleep infinity
```

```bash
kubectl apply -f api.yaml
bash courses/course-01-ops-security/challenges/16-crashloop-mystery/verify.sh
```

The new ReplicaSet rolls out brand-new pods that start from restart count `0` — which is exactly what the verifier's "fresh, stable" check confirms.

## Why `set env` and not `kubectl edit` on a pod

Never edit the *pod* — it's owned by a ReplicaSet and your change will be reverted (or lost on the next restart). Always change the **controller** (Deployment), and let it roll the pods. `kubectl set env deploy/api ...` does exactly that in one line.

## The broader diagnostic map

A CrashLoopBackOff is one symptom with many causes. Match what `describe`/`logs` show to the cause:

| Signal from `describe` / `logs` | Likely cause | Fix |
|---------------------------------|--------------|-----|
| Exit `1` + app error in `--previous` | Missing/invalid config (our case: env var, config file, bad DSN) | Supply the config; validate it |
| `Reason: OOMKilled`, exit `137` | Memory limit too low for the workload | Raise `resources.limits.memory`; find the leak |
| Exit `137` + `Liveness probe failed` events | Liveness probe too aggressive or pointing at the wrong port/path | Fix the probe target; raise `initialDelaySeconds`/`failureThreshold` |
| Exit `127`, "not found" in log | Bad `command`/`args` or missing binary in image | Correct the entrypoint; verify the binary exists in the image |
| Exit `0`, still restarting | A run-to-completion process in a Deployment | Use a `Job`/`CronJob`, or make the process long-lived |

## Hardening preview

Fail-fast is *good* design — an app that refuses to start on bad config beats one that boots and silently misbehaves. Make the failure loud and cheap to diagnose:

- Validate required config at startup and **log the exact missing key** (this app does — that's why `--previous` solved it instantly).
- Source required config from a `Secret`/`ConfigMap` via `envFrom` or `valueFrom`, and treat a missing key as a deploy-blocking error in CI, not a 2am page.
- Add a `readinessProbe` so a half-initialized pod never receives traffic even if it does manage to start.
