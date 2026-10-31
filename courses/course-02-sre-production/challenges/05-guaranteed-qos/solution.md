# Solution — Guarantee It

One edit to the `cache` container's `resources` block: add `limits` equal to the existing `requests` for both cpu and memory. The flag is `KUBE{requests_equal_limits_is_guaranteed}`.

## The fix

```yaml
# cache-patch (the relevant slice of the pod template)
spec:
  template:
    spec:
      containers:
        - name: cache
          image: redis:7.2-alpine
          resources:
            requests:
              cpu: 100m
              memory: 64Mi
            limits:
              cpu: 100m        # == requests.cpu
              memory: 64Mi     # == requests.memory
```

Apply it declaratively, or patch in place:

```bash
kubectl -n dojo-qos patch deploy cache --type merge -p '{
  "spec": {"template": {"spec": {"containers": [
    {"name": "cache", "resources": {
      "requests": {"cpu": "100m", "memory": "64Mi"},
      "limits":   {"cpu": "100m", "memory": "64Mi"}
    }}
  ]}}}
}'

kubectl -n dojo-qos rollout status deploy/cache
```

Confirm the kubelet's verdict on the **live pods** — this is exactly what the verifier reads:

```bash
kubectl -n dojo-qos get pods -l app=cache \
  -o custom-columns=POD:.metadata.name,QOS:.status.qosClass
# POD              QOS
# cache-xxxxxxxx   Guaranteed
# cache-yyyyyyyy   Guaranteed
```

Then run the verifier:

```bash
bash courses/course-02-sre-production/challenges/05-guaranteed-qos/verify.sh
```

## Why this is correct

- **`status.qosClass` is computed, not declared.** You never write `qosClass: Guaranteed` — the kubelet derives it from the resource spec at pod admission and stamps it onto status. That's why the verifier inspects `status`, not your manifest: it checks the *verdict*, not your intent. Equal requests and limits on every resource of every container is the only path to Guaranteed.
- **Equal values matter, units don't have to be identical.** `100m` cpu request vs `100m` limit is equal; `memory: 64Mi` both sides is equal. If you wrote `requests.memory: 64Mi` and `limits.memory: 67108864` (same number of bytes) they still compare equal — Kubernetes normalizes quantities. What breaks Guaranteed is a *different* value, or a *missing* one.
- **Limits-only would also work, but requests-only never does.** If you had set only `limits`, Kubernetes auto-fills `requests` to match and you'd land in Guaranteed anyway. The setup shipped requests-only — the one combination that leaves you Burstable — which is why adding equal limits is the fix.

## Prove the behavior (optional)

The Guaranteed guarantee is about *order under pressure*. You can read the kernel bias the kubelet set:

```bash
POD=$(kubectl -n dojo-qos get pods -l app=cache -o jsonpath='{.items[0].metadata.name}')
kubectl -n dojo-qos exec "$POD" -- cat /proc/1/oom_score_adj
# -> -997   (Guaranteed; a BestEffort pod would show 1000, Burstable something in between)
```

That `-997` is the whole payoff: when the node's memory manager starts reaping, this pod is near the bottom of the kill list.

## The trap: one container ruins the pod

QoS is a **pod-level** verdict over **all** containers. If you later add a logging sidecar:

```yaml
      containers:
        - name: cache        # perfect: requests == limits
          # ...
        - name: log-shipper  # no resources at all
          image: fluent-bit:3.1
```

the pod silently drops back to **Burstable** — the sidecar has no requests/limits, so the pod no longer satisfies "every container." The verifier would go red again. The fix is to give *every* container, sidecars included, matching requests and limits. This is the single most common reason a team swears they "set Guaranteed" but `status.qosClass` says otherwise.

## Hardening preview

Guaranteed is a per-pod choice; at the namespace level you enforce the floor with a **`LimitRange`**, which stamps default requests/limits onto any container that omits them — turning "forgot to set resources" from a silent BestEffort pod into a sane default:

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: cache-defaults
  namespace: dojo-qos
spec:
  limits:
    - type: Container
      default:          # becomes the limit if unset
        cpu: 100m
        memory: 64Mi
      defaultRequest:   # becomes the request if unset
        cpu: 100m
        memory: 64Mi
```

Set `default == defaultRequest` and every container that forgets its resources is *defaulted into Guaranteed* instead of falling to BestEffort — defense in depth for the exact bug this challenge planted.
