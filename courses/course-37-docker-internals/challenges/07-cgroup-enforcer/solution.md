# Solution: Cgroup Enforcer

## Step 1 — Confirm there are no limits

```bash
kubectl get deployment hog -n dojo-docker-cgroup \
  -o jsonpath='{.spec.template.spec.containers[0].resources}'
# Output: {} — empty, no limits set
```

## Step 2 — Patch the Deployment

```bash
kubectl patch deployment hog -n dojo-docker-cgroup \
  --type=json \
  -p='[{
    "op": "replace",
    "path": "/spec/template/spec/containers/0/resources",
    "value": {
      "requests": {"cpu": "100m", "memory": "128Mi"},
      "limits":   {"cpu": "100m", "memory": "128Mi"}
    }
  }]'
```

Or edit directly:
```bash
kubectl edit deployment hog -n dojo-docker-cgroup
# Add under containers[0]:
#   resources:
#     requests:
#       cpu: "100m"
#       memory: "128Mi"
#     limits:
#       cpu: "100m"
#       memory: "128Mi"
```

## Step 3 — Verify the cgroup was set on the node

```bash
# Wait for pod to restart with new limits
kubectl rollout status deployment/hog -n dojo-docker-cgroup

POD=$(kubectl get pod -n dojo-docker-cgroup -l app=hog -o jsonpath='{.items[0].metadata.name}')

# Get the pod UID to find its cgroup path
UID=$(kubectl get pod "$POD" -n dojo-docker-cgroup -o jsonpath='{.metadata.uid}')

# Look inside the kind node
docker exec dojo-control-plane \
  find /sys/fs/cgroup -name "memory.max" -path "*$UID*" 2>/dev/null | head -1 | xargs cat
# Output: 134217728  (= 128 MiB in bytes)

docker exec dojo-control-plane \
  find /sys/fs/cgroup -name "cpu.max" -path "*$UID*" 2>/dev/null | head -1 | xargs cat
# Output: 10000 100000  (= 100m = 0.1 cores)
```

## Step 4 — Verify with the verifier

```bash
bash courses/course-37-docker-internals/challenges/07-cgroup-enforcer/verify.sh
```

**Flag:** `KUBE{cgroup_throttles_at_the_kernel}`

## QoS Classes and Why They Matter

| requests == limits | requests < limits | no requests/limits |
|---|---|---|
| `Guaranteed` | `Burstable` | `BestEffort` |
| Scheduler reserves exact amount, cgroup hard limits enforced | Can burst to limit if capacity available | Gets whatever's left, first to be killed under pressure |

Setting equal requests and limits gives you the `Guaranteed` QoS class — the best protection against being OOM-killed when the node is under pressure.

## The 100m CPU Unit

`100m` means 100 millicores = 0.1 of one CPU core. The kernel implements this as a CFS (Completely Fair Scheduler) quota: the cgroup gets 10ms of CPU time every 100ms period (10/100 = 10% = 0.1 cores). If the container tries to use more, the kernel throttles it — the process simply doesn't get scheduled during the remaining 90ms of each period.
