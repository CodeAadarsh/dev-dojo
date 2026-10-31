# Solution — Anti-Affinity Spread for StatefulSets

Patch the StatefulSet to add a `requiredDuringSchedulingIgnoredDuringExecution` podAntiAffinity rule keyed on `kubernetes.io/hostname`, then delete the existing pods to force rescheduling.

```yaml
# cache-sts-spread.yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: cache
  namespace: dojo-spread
  labels:
    app: cache
spec:
  serviceName: cache
  replicas: 3
  selector:
    matchLabels:
      app: cache
  template:
    metadata:
      labels:
        app: cache
    spec:
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels:
                  app: cache
              topologyKey: kubernetes.io/hostname
      containers:
        - name: cache
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
            limits:
              cpu: 200m
              memory: 64Mi
```

Apply and trigger rescheduling:

```bash
kubectl apply -f cache-sts-spread.yaml
# The StatefulSet spec is updated but existing pods are not replaced automatically
# (StatefulSet rolling update only fires on template changes; affinity IS part of
# the template, so a rollout is triggered — wait for it):
kubectl -n dojo-spread rollout status sts/cache
# If the rollout seems stuck, force a pod restart:
kubectl -n dojo-spread delete pods -l app=cache
kubectl -n dojo-spread get pods -o wide      # confirm spread
bash courses/course-08-stateful-data/challenges/06-anti-affinity-spread/verify.sh
```

## Why each piece matters

**`requiredDuringSchedulingIgnoredDuringExecution` vs `preferredDuring...`.**
`required` is a hard rule: the scheduler rejects a node that violates it, leaving the pod `Pending` rather than colocating. `preferred` is a hint: the scheduler tries to honor it but will collocate if no other node is available. For a cache tier you care about — use `required`. The `IgnoredDuringExecution` suffix means the rule is only enforced at scheduling time; if a node's labels change *after* a pod is placed, the running pod is not evicted. `RequiredDuringExecution` (not yet GA) would evict — useful for strict compliance but operationally risky.

**`topologyKey: kubernetes.io/hostname`.**
This key is automatically applied to every node by kubelet. Using it as the topology domain means "one pod per unique hostname." For zone-level spread (e.g., us-east-1a/b/c) use `topology.kubernetes.io/zone` — same mechanism, different granularity. Picking the right topology key is the whole art of spread rules.

**Why the control-plane was untainted.**
The dojo cluster has 1 control-plane + 2 workers. With 3 replicas and a hard anti-affinity on hostname, you need 3 distinct schedulable nodes. In production this means provisioning enough worker nodes to satisfy your replica count. In the dojo we remove the `NoSchedule` taint from the control-plane instead. If you see a pod stuck `Pending` with event `0/3 nodes are available: 2 node(s) had untolerated taint`, the control-plane taint came back — re-run setup.sh.

**StatefulSets and rolling updates.**
Unlike a Deployment, a StatefulSet rolls pods one at a time in reverse-ordinal order (`cache-2`, then `cache-1`, then `cache-0`) by default. This serialized rollout is what gives each pod a stable identity during updates. After applying the affinity change, the controller updates each pod in order — if your anti-affinity rule would leave a pod unschedulable mid-rollout, the rollout stalls. Size your cluster accordingly.

## Prove the spread with node counts

```bash
kubectl -n dojo-spread get pods -o wide --no-headers \
  | awk '{print $7}' | sort | uniq -c
# -> 1 dojo-control-plane
#    1 dojo-worker
#    1 dojo-worker2
```

Each hostname appears exactly once — that's the guarantee you're paying for.
