# Solution: Canary Rollout

## canary.yaml

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dojo-web-canary
  namespace: dojo-cicd
  labels:
    app: dojo-web
    track: canary
spec:
  replicas: 1
  selector:
    matchLabels:
      app: dojo-web
      track: canary
  template:
    metadata:
      labels:
        app: dojo-web    # shared with stable — Service routes to this
        track: canary    # unique to canary — stable's selector ignores these pods
        version: v1.1.0
    spec:
      containers:
      - name: web
        image: nginx:1.27-alpine
        ports:
        - containerPort: 80
        resources:
          requests:
            cpu: 10m
            memory: 16Mi
          limits:
            memory: 32Mi
```

Apply it:

```bash
kubectl apply -f ~/.kube-dojo-work/05-canary-rollout/canary.yaml
kubectl -n dojo-cicd rollout status deploy/dojo-web-canary
```

## Why the label strategy works

The `dojo-web` Service has `spec.selector: { app: dojo-web }`. kube-proxy
builds its endpoint list from **all** pods that match that selector — both
`dojo-web-stable` pods (3) and `dojo-web-canary` pods (1). Each new TCP
connection is sent to a random endpoint from that pool.

`4 endpoints total → 1 hits canary → ~25% traffic`. The traffic knob is
**replica count**, not DNS, not routing rules.

The Deployments do not share a selector — `dojo-web-stable` selects
`track: stable`, `dojo-web-canary` selects `track: canary`. This isolation
means neither Deployment's rollout controller touches the other's pods.

## Verify the traffic split manually

```bash
# Watch endpoints in real time
kubectl -n dojo-cicd get endpoints dojo-web -w

# Port-forward the Service and curl 40 times; count which pod responds
kubectl -n dojo-cicd port-forward svc/dojo-web 18580:80 &
for i in $(seq 40); do curl -s http://localhost:18580/ -o /dev/null; done
kill %1
```

## Rollout progression

| Phase | Stable replicas | Canary replicas | Canary % |
|-------|-----------------|-----------------|----------|
| Initial canary | 3 | 1 | ~25% |
| Growing canary | 3 | 3 | ~50% |
| Majority canary | 1 | 3 | ~75% |
| Full rollout | 0 | 4 | 100% |

At full rollout, rename the canary Deployment to stable and delete the old
one, or scale stable to 0 and promote canary.

## Rollback

```bash
kubectl -n dojo-cicd scale deploy/dojo-web-canary --replicas=0
# All traffic returns to stable instantly — no DNS TTL, no downtime.
```

## Limitations of replica-ratio canary

This pattern has **no per-request control**. A sticky-session user may hit the
canary every time, or never. Header-based routing (e.g., `canary: true`),
weight-based routing, and percentage-based traffic policies all require a
service mesh (Istio/Linkerd) or an ingress controller with traffic-splitting
support (NGINX Plus, Argo Rollouts). For production progressive delivery with
telemetry-driven promotion, use Argo Rollouts with a metric analysis step —
the replica-ratio approach is the fallback that works with zero additional
infrastructure.

## Attacker's view

From a security standpoint, the canary Deployment runs with the same RBAC,
network policies, and admission controls as stable. A canary pod that escapes
its container has the same blast radius as a stable pod escape. Canary
deployments reduce functional blast radius (bugs) but do not reduce security
blast radius. Namespace-isolating the canary (`dojo-cicd-canary` vs
`dojo-cicd`) with tighter network policies narrows the attack surface during
the validation window.
