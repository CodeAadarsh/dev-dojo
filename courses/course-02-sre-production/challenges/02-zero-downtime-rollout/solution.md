# Solution — Zero-Downtime Rollout

One manifest brings the Deployment to the target state. The three load-bearing changes are the `strategy` block, the `readinessProbe`, and `minReadySeconds`.

```yaml
# web.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: dojo-rollout
  labels:
    app: web
spec:
  replicas: 3
  minReadySeconds: 5              # (3) a new pod must stay Ready 5s before it counts
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0           # (1) never drop below desired capacity...
      maxSurge: 1                 #     ...add one new pod before removing an old one
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
          readinessProbe:          # (2) only receive traffic once it can answer
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 2
            periodSeconds: 5
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
            limits:
              cpu: 200m
              memory: 64Mi
```

Apply and wait for the rollout to settle before verifying:

```bash
kubectl apply -f web.yaml
kubectl -n dojo-rollout rollout status deploy/web
bash courses/course-02-sre-production/challenges/02-zero-downtime-rollout/verify.sh
```

## The one-liner path (fast, in-place)

If you'd rather patch the live object than write YAML, three commands do it. Note the `strategy`/`minReadySeconds` patch is a strategic-merge patch; the probe is easiest via `kubectl set` on modern kubectl, or a second merge patch:

```bash
kubectl -n dojo-rollout patch deploy web --type=merge -p '{
  "spec": {
    "minReadySeconds": 5,
    "strategy": {"type":"RollingUpdate","rollingUpdate":{"maxUnavailable":0,"maxSurge":1}}
  }
}'

kubectl -n dojo-rollout patch deploy web --type=merge -p '{
  "spec": {"template": {"spec": {"containers": [{
    "name":"web",
    "readinessProbe": {"httpGet":{"path":"/","port":80},"initialDelaySeconds":2,"periodSeconds":5}
  }]}}}
}'

kubectl -n dojo-rollout rollout status deploy/web
```

## Why each piece is correct

- **`maxUnavailable: 0` is the capacity floor.** It tells the Deployment controller: *do not terminate an old pod until a replacement is available.* On its own it would deadlock a rollout (you can't remove a pod, and by default you can't add one either), which is why it must be paired with surge.
- **`maxSurge: 1` is what lets progress happen.** It permits one *extra* pod above `replicas` during the rollout. Combined with `maxUnavailable: 0`, the dance becomes strictly *add-then-remove*: bring up a new pod, wait for it to become available, then retire one old pod. Capacity never dips below desired. (`maxSurge` and `maxUnavailable` can't both be 0 — that's a wedged rollout, and the verifier rejects it.)
- **`readinessProbe` is what makes the surge honest.** "Available" is built on "Ready," and without a probe, Ready is a lie — it means the process started, not that it can serve. The probe gates the Service endpoints: a pod is only added to the load balancer's rotation once `GET /` returns 2xx. This is the difference between a seamless rollout and the 502 sawtooth.
- **`minReadySeconds: 5` adds soak time.** The Deployment controller won't count a pod toward "available" until it has been continuously Ready for 5 seconds. This catches the pod that passes one probe then dies — without it, the controller would already have evicted an old pod and left you genuinely short.

## Prove it actually works

Watch a rolling update and confirm Ready count never dips below 3:

```bash
# in terminal 1: watch pods churn
kubectl -n dojo-rollout get pods -w

# in terminal 2: trigger a rollout by bumping the image tag
kubectl -n dojo-rollout set image deploy/web web=nginx:1.27
kubectl -n dojo-rollout rollout status deploy/web
```

You should see a *fourth* pod appear (the surge) and go Ready before any old pod is terminated — and the count of Ready pods should never fall below 3. Contrast with the planted defaults, where you'd see a pod go `Terminating` while its cold replacement was still coming up.

Inspect the rollout history and roll back if a bad image ever ships:

```bash
kubectl -n dojo-rollout rollout history deploy/web
kubectl -n dojo-rollout rollout undo deploy/web          # back to previous revision
```

## SRE framing — what you actually bought, and what's still exposed

- **This protects against *rollouts*, not *node death*.** `maxUnavailable: 0` only governs the Deployment's own pod replacement. If a node hosting two of your three pods dies, the Deployment reschedules them but you're briefly down to one — that's what a `PodDisruptionBudget` and anti-affinity are for (the next challenge covers the PDB side of this).
- **A readiness probe that's too cheap lies; one that's too expensive flaps.** `GET /` on nginx is fine here, but for a real app the readiness endpoint should check the dependencies the request path actually needs (DB pool, cache) — and *not* ones it can tolerate being down, or a flaky dependency will yank healthy pods out of rotation and amplify an outage. Keep `livenessProbe` and `readinessProbe` distinct: liveness restarts a wedged pod, readiness only removes it from the load balancer.
- **Don't let an HPA and a hand-set `replicas` fight.** If this Deployment is also autoscaled (previous challenge), never write `replicas` by hand once the HPA owns it — they tug-of-war. The rollout strategy and `minReadySeconds` still apply; they're orthogonal to who owns the replica count.
