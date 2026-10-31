# Solution — Autoscale Under Load

Two equivalent paths. The declarative manifest is the one you'd commit to GitOps; the imperative one is the fast CKAD/incident move.

## Path A — the `autoscaling/v2` manifest (commit this)

```yaml
# web-hpa.yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: web
  namespace: dojo-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: web                 # (2) point at the Deployment by name
  minReplicas: 2              # (5) never serve from a single pod
  maxReplicas: 5              #     headroom to absorb the campaign spike
  metrics:
    - type: Resource          # (3) a built-in resource metric...
      resource:
        name: cpu             #     ...on CPU...
        target:
          type: Utilization   #     ...as a % of the pod's CPU *request*
          averageUtilization: 50   # (4) scale to keep avg CPU near 50%
```

Apply and verify:

```bash
kubectl apply -f web-hpa.yaml
kubectl -n dojo-hpa get hpa web
bash courses/course-02-sre-production/challenges/01-autoscale-under-load/verify.sh
```

## Path B — imperative, in one line

```bash
kubectl -n dojo-hpa autoscale deploy web --cpu-percent=50 --min=2 --max=5
```

On any modern kubectl this creates an `autoscaling/v2` HPA with exactly the spec above. Confirm the shape:

```bash
kubectl -n dojo-hpa get hpa web -o yaml | grep -A6 metrics
```

## Why each piece is correct

- **`averageUtilization: 50` is a percentage of the CPU *request*, not of a core.** The Deployment requests `100m`, so 50% utilization means the controller aims to keep average pod CPU near `50m`. This is exactly why the request had to exist first — it's the denominator. Change it to `type: AverageValue` with `averageValue: 50m` and you've pinned to an absolute figure that ignores the request; the verifier rejects that on purpose because `Utilization` is what you almost always want.
- **`minReplicas: 2`** keeps you resilient at idle — a single pod is a single point of failure and gives the HPA nothing to drain to during a rollout. **`maxReplicas: 5`** is your blast-radius cap: it bounds cost and stops a metric bug or a traffic flood from scaling you into the ground.
- **The HPA is a control loop, not a one-shot.** Every ~15s the controller reads CPU from the metrics API and computes `desiredReplicas = ceil(currentReplicas × currentUtilization / targetUtilization)`, clamped to `[min, max]`. It also has built-in stabilization (default 5-min scale-down window) so it doesn't flap.

## Prove it actually scales (optional)

The verifier only reads the spec, so you can pass without this. To watch it work you need **metrics-server** (kind doesn't ship one):

```bash
# metrics-server, patched for kind's self-signed kubelet certs
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl -n kube-system patch deploy metrics-server --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
kubectl -n kube-system rollout status deploy/metrics-server

# now kubectl top works
kubectl top pods -n dojo-hpa
```

Generate load and watch replicas climb:

```bash
# a busybox pod hammering the service in a tight loop
kubectl -n dojo-hpa run load --image=busybox:1.36 --restart=Never -- \
  /bin/sh -c "while true; do wget -q -O- http://web.dojo-hpa.svc >/dev/null; done"

# watch the HPA react (TARGETS climbs, REPLICAS follows up to 5)
kubectl -n dojo-hpa get hpa web -w
```

Clean up the load generator with `kubectl -n dojo-hpa delete pod load`.

## SRE framing — what you actually bought

You converted a recurring 3am page ("scale web for the campaign") into a declarative control loop that reconciles forever. That's toil elimination in its purest form: one author, zero ongoing operators. The follow-ups a staff engineer would ask next:

- **Does the HPA fight your rollout?** Pair it with a PodDisruptionBudget and a sane `maxUnavailable`, and never set `replicas` on the Deployment by hand once an HPA owns it — they'll tug-of-war.
- **Is CPU even the right signal?** For a latency-bound or queue-driven service, scale on a custom/external metric (requests-per-second, queue depth) via `type: Pods`/`type: External` instead of CPU. CPU is the default, not the answer.
- **What about scaling the node pool?** An HPA adds pods; if the cluster runs out of room, you also need the Cluster Autoscaler (or Karpenter) underneath it. HPA and cluster autoscaling are two different loops that have to agree.
