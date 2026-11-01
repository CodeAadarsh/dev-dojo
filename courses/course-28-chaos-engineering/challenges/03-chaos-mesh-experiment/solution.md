# Solution — Chaos Mesh Experiment

## Step 0 — Install Chaos Mesh (if not done)

```bash
helm repo add chaos-mesh https://charts.chaos-mesh.org
helm repo update
helm install chaos-mesh chaos-mesh/chaos-mesh \
  --namespace chaos-mesh \
  --create-namespace \
  --version 2.7.0 \
  --set chaosDaemon.runtime=containerd \
  --set chaosDaemon.socketPath=/run/containerd/containerd.sock

# Wait for all components to be Running
kubectl -n chaos-mesh rollout status deployment/chaos-controller-manager
kubectl -n chaos-mesh get pods
```

Confirm CRDs are registered:

```bash
kubectl get crd | grep chaos-mesh
# podchaos.chaos-mesh.org, networkchaos.chaos-mesh.org, ...
```

## Option A — PodChaos (pod-kill)

```yaml
# kill-experiment.yaml
apiVersion: chaos-mesh.org/v1alpha1
kind: PodChaos
metadata:
  name: kill-experiment
  namespace: dojo-chaos
spec:
  action: pod-kill
  mode: one
  selector:
    namespaces:
      - dojo-chaos
    labelSelectors:
      app: web
  duration: "1m"
```

```bash
kubectl apply -f kill-experiment.yaml

# Confirm the CR exists and has the right fields
kubectl -n dojo-chaos get podchaos kill-experiment \
  -o jsonpath='{.spec.action}{" | ns:"}{.spec.selector.namespaces[0]}{"\n"}'
# pod-kill | ns:dojo-chaos

bash courses/course-28-chaos-engineering/challenges/03-chaos-mesh-experiment/verify.sh
```

## Option B — NetworkChaos (latency injection)

```yaml
# delay-experiment.yaml
apiVersion: chaos-mesh.org/v1alpha1
kind: NetworkChaos
metadata:
  name: delay-experiment
  namespace: dojo-chaos
spec:
  action: delay
  mode: all
  selector:
    namespaces:
      - dojo-chaos
    labelSelectors:
      app: web
  delay:
    latency: "100ms"
    correlation: "25"
    jitter: "10ms"
  duration: "2m"
```

```bash
kubectl apply -f delay-experiment.yaml
bash courses/course-28-chaos-engineering/challenges/03-chaos-mesh-experiment/verify.sh
```

## What actually happens at the node level

Chaos Mesh has three components that work together:

1. **chaos-controller-manager** — watches PodChaos/NetworkChaos CRs and coordinates which daemon handles each target pod.
2. **chaos-daemon** (DaemonSet) — runs on every node, has access to the container runtime socket (containerd). For `pod-kill`, it calls `containerd` directly to stop the container. For `NetworkChaos`, it enters the target pod's network namespace and applies `tc qdisc` rules to inject latency/loss at the kernel level.
3. **chaos-webhook** — mutates pod specs to inject a chaos sidecar when needed (for some experiment types).

The key difference from `kubectl delete pod`: the daemon uses the container runtime API to kill the container, not the Kubernetes API. This means the kubelet sees the container exit and marks it for restart — but the pod object itself is not deleted. This is a `pod-failure` semantic. `pod-kill` additionally calls the Kubernetes Eviction API to remove the pod and let the RS controller re-create it.

## Cleanup

```bash
kubectl -n dojo-chaos delete podchaos --all
kubectl -n dojo-chaos delete networkchaos --all

# Remove Chaos Mesh entirely when done with this course
helm uninstall chaos-mesh -n chaos-mesh
kubectl delete namespace chaos-mesh
```

## Blast-radius discipline (attacker's view)

A misconfigured `selector.namespaces: []` (or omitted) in Chaos Mesh v2.x defaults to cluster-wide targeting. An experiment that accidentally kills pods in `kube-system` can take down CoreDNS, which breaks DNS for every workload simultaneously. An experiment that kills `chaos-mesh` pods can orphan in-progress chaos, leaving network rules permanently in place. Always verify your selector before applying:

```bash
kubectl apply --dry-run=server -f chaos-experiment.yaml
kubectl -n dojo-chaos get podchaos -o jsonpath='{.items[*].spec.selector}'
```
