# Chaos Mesh Experiment

Ad-hoc `kubectl delete pod` only takes you so far. Real GameDay tooling needs **declarative chaos**: a CR you commit to Git, schedule via a controller, scope with blast-radius controls, and trigger on demand or on a cron. This is what Chaos Mesh gives you.

## Prerequisite — Install Chaos Mesh

Chaos Mesh ships as a Helm chart. Install it into your dojo cluster first:

```bash
helm repo add chaos-mesh https://charts.chaos-mesh.org
helm repo update
helm install chaos-mesh chaos-mesh/chaos-mesh \
  --namespace chaos-mesh \
  --create-namespace \
  --version 2.7.0 \
  --set chaosDaemon.runtime=containerd \
  --set chaosDaemon.socketPath=/run/containerd/containerd.sock

# Wait for the controller and daemon to come up
kubectl -n chaos-mesh rollout status deployment/chaos-controller-manager
kubectl -n chaos-mesh get pods
```

All three components should be `Running`: `chaos-controller-manager`, `chaos-daemon` (DaemonSet, one per node), and optionally `chaos-dashboard`.

## Setup

Run `setup.sh`. It deploys a target `web` Deployment in `dojo-chaos` (or reuses one if already present from a prior challenge).

## Mission

Author either a **PodChaos** or **NetworkChaos** CR in namespace `dojo-chaos`. The CR must satisfy:

1. API version `chaos-mesh.org/v1alpha1`.
2. `spec.action` set to a valid value:
   - PodChaos: `pod-kill`, `pod-failure`, or `container-kill`
   - NetworkChaos: `delay`, `loss`, `duplicate`, or `corrupt`
3. `spec.selector.namespaces[0]` equal to `dojo-chaos` (blast-radius scoped).
4. A bounded duration (`spec.duration` field) so the experiment has a defined end.

### Example PodChaos

```yaml
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

### Example NetworkChaos

```yaml
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

Apply your CR:

```bash
kubectl apply -f chaos-experiment.yaml
kubectl -n dojo-chaos get podchaos      # or: kubectl -n dojo-chaos get networkchaos
```

## What `verify.sh` checks

| Check | Required |
|-------|----------|
| Chaos Mesh CRD | `podchaos.chaos-mesh.org` or `networkchaos.chaos-mesh.org` installed |
| CR in `dojo-chaos` | At least one PodChaos or NetworkChaos object |
| `spec.action` | Non-empty string |
| `spec.selector.namespaces[0]` | `dojo-chaos` |

The verifier checks the **CR object structure**, not whether chaos is actively running. Author a valid CR, apply it, run verify.

## Blast-radius discipline

Always scope `selector.namespaces` tightly to your target namespace. A CR that targets `""` (all namespaces) or omits the namespace selector will happily kill pods in `kube-system`, `chaos-mesh`, or wherever else your workloads live. A well-scoped experiment is the difference between a controlled GameDay and a self-inflicted outage. `dojo-chaos` is your blast radius here — nothing outside it should be affected.
