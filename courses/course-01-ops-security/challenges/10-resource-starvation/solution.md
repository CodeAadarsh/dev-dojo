# Solution — Resource Starvation

Two things fix this: explicit requests/limits on the `api` container (which decides *its* QoS), and a `LimitRange` that stops the next forgetful manifest from ever being BestEffort in this namespace.

## 1. Give the container requests and limits

The fast imperative route:

```bash
kubectl -n dojo-resources set resources deploy/api \
  --requests=cpu=100m,memory=64Mi \
  --limits=cpu=250m,memory=128Mi
```

Or the YAML you'd commit:

```yaml
# api-resources.yaml — patch the container
spec:
  template:
    spec:
      containers:
        - name: api
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: 100m        # scheduler reserves this; eviction ranks by overage
              memory: 64Mi
            limits:
              cpu: 250m        # CPU throttled here (never killed for CPU)
              memory: 128Mi    # exceed this and the container is OOM-killed instantly
```

```bash
kubectl apply -f api-resources.yaml   # (or the `set resources` command above)
kubectl -n dojo-resources rollout status deploy/api
```

With `requests != limits` this pod is now **Burstable** — out of the death-first BestEffort class. If you want it **Guaranteed** (evicted last), set `requests == limits` for *both* cpu and memory:

```bash
kubectl -n dojo-resources set resources deploy/api \
  --requests=cpu=250m,memory=128Mi --limits=cpu=250m,memory=128Mi
# -> QoS class: Guaranteed
```

Confirm the class you earned:

```bash
kubectl -n dojo-resources get pod -l app=api \
  -o jsonpath='{.items[0].status.qosClass}{"\n"}'
```

## 2. Make the namespace safe by default — the LimitRange

A `LimitRange` is an admission-time mutating/validating control scoped to one namespace. It can supply **defaults** (so a container with nothing set inherits requests/limits) and enforce **min/max** bounds:

```yaml
# limitrange.yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: dojo-resources-defaults
  namespace: dojo-resources
spec:
  limits:
    - type: Container
      default:                 # becomes the container's LIMITS if unset
        cpu: 250m
        memory: 128Mi
      defaultRequest:          # becomes the container's REQUESTS if unset
        cpu: 100m
        memory: 64Mi
      min:                     # reject pods asking for less than this
        cpu: 10m
        memory: 16Mi
      max:                     # reject pods asking for more than this
        cpu: "1"
        memory: 512Mi
```

```bash
kubectl apply -f limitrange.yaml
kubectl -n dojo-resources describe limitrange dojo-resources-defaults
```

Now any pod created in `dojo-resources` without resources gets `default`/`defaultRequest` stamped on at admission — it can never be BestEffort again. Prove it:

```bash
kubectl -n dojo-resources run probe --image=nginx:1.27-alpine --restart=Never
kubectl -n dojo-resources get pod probe \
  -o jsonpath='{.spec.containers[0].resources}{"\n"}'   # inherited the defaults
kubectl -n dojo-resources get pod probe \
  -o jsonpath='{.status.qosClass}{"\n"}'                # Burstable, not BestEffort
kubectl -n dojo-resources delete pod probe
```

> **Why the LimitRange doesn't fix the existing `api` pod by itself:** defaults are applied only to objects created *after* the LimitRange exists. The already-running `api` pods keep their old (empty) spec until the next rollout. That's why step 1 sets values explicitly — don't rely on the net to catch a pod that's already fallen. If you *want* the LimitRange to supply `api`'s values, apply it first, then `kubectl -n dojo-resources rollout restart deploy/api`.

## Why each piece matters

- **requests vs limits do different jobs.** The scheduler only looks at **requests** to decide placement, and the eviction ranking is by QoS + how far a pod is over its memory **request**. **Limits** are hard ceilings: CPU is *throttled* at the limit (cgroup `cpu.max`), memory over the limit is an immediate kernel OOM-kill of that container. Setting only requests leaves you unbounded; setting only limits (with requests defaulting equal to limits) can over-reserve. Set both deliberately.
- **Don't set a CPU limit reflexively.** CPU is compressible — hitting the limit just throttles, adding latency. For latency-sensitive services many teams set CPU *requests* but omit CPU *limits* to avoid throttling, while always setting a memory limit (memory is incompressible — the only way to cap it is to kill). This challenge requires a CPU limit to teach the mechanism; in production, choose it on purpose.
- **memory request well below the limit invites eviction.** Under node pressure the kubelet targets pods using more than they requested. If you request `64Mi` but routinely use `120Mi`, you're a prime eviction candidate even though you're under your limit. Right-size the request to real usage (look at your LGTM/Prometheus `container_memory_working_set_bytes`), not to a guess.

## The SRE framing

Capacity is a contract. `requests` are what you promise the scheduler you need (and what it bills against node allocatable); `limits` are what you promise never to exceed. A namespace full of BestEffort pods is a cluster where the *kernel* decides what dies at 02:14 — and it will choose badly. A `LimitRange` for defaults plus a `ResourceQuota` for namespace totals (the next step up) move that decision from the OOM killer back to you.
