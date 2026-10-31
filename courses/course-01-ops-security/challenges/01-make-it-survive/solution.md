# Solution — Make It Survive

One manifest brings the Deployment to the target state; a second adds the PDB.

```yaml
# web.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: dojo-resilient
  labels:
    app: web
spec:
  replicas: 3                      # (1) no single point of failure
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0            # (3) never drop below desired capacity...
      maxSurge: 1                  #     ...add one new pod before removing an old one
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
          readinessProbe:          # (2) only receive traffic when actually ready
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 2
            periodSeconds: 5
          resources:               # (4) schedulable + Burstable QoS, not BestEffort
            requests:
              cpu: 50m
              memory: 32Mi
            limits:
              cpu: 200m
              memory: 64Mi
---
# web-pdb.yaml  (5)
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: web-pdb
  namespace: dojo-resilient
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: web
```

Apply and verify:

```bash
kubectl apply -f web.yaml -f web-pdb.yaml
kubectl -n dojo-resilient rollout status deploy/web
bash courses/course-01-ops-security/challenges/01-make-it-survive/verify.sh
```

## Why each piece matters

- **`maxUnavailable: 0` + `readinessProbe`** is the real zero-downtime combination. `maxUnavailable: 0` says "don't kill an old pod until a new one exists," and the readiness probe says "don't route to the new pod until it answers." Either one alone is insufficient: without the probe, you route to a pod that isn't ready; without `maxUnavailable: 0`, you can dip below capacity mid-rollout.
- **PDB** only governs *voluntary* disruptions (drains, upgrades) — it does **not** protect against a node crashing. `minAvailable: 2` means an admin draining a node will be blocked from evicting a pod if doing so would leave fewer than 2 running, forcing the drain to proceed pod-by-pod as replacements come up.
- **Resource requests** move the pod out of the *BestEffort* QoS class into *Burstable*, so it's not first in line for the OOM killer under node memory pressure.

## Prove it actually works

Watch a rolling update stay at full capacity:

```bash
kubectl -n dojo-resilient set image deploy/web web=nginx:1.27 && \
kubectl -n dojo-resilient get pods -w
```

You'll never see Ready pods drop below 3 — that's the whole point.
