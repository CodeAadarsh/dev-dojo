# Solution — Ship the Operator

Complete walkthrough, step by step. The operator code is already correct — your work is the deployment pipeline.

## Step 0 — Confirm context

```bash
kubectl config current-context   # must be kind-dojo
kubectl get nodes -o wide        # three Ready nodes
```

Never skip this. Deploying to the wrong cluster because of a stale context has caused real incidents.

## Step 1 — Fetch Go dependencies

```bash
cd ~/.kube-dojo-work/06-ship-the-operator
go mod tidy
```

`go mod tidy` downloads dependencies and writes `go.sum`. This is required before the Docker build because the Dockerfile runs `go mod tidy` inside the builder layer (which requires internet access during build). The `go.sum` file pins each module's content hash and prevents supply-chain attacks — commit it to source control in real projects.

## Step 2 — Build the image

```bash
docker build -t widget-controller:dev .
```

The Dockerfile is a multi-stage build:

```
Stage 1 — golang:1.22-alpine (builder)
  go mod tidy + CGO_ENABLED=0 go build → /manager (static binary, no libc deps)

Stage 2 — gcr.io/distroless/static:nonroot (runtime)
  copies /manager only; no shell, no package manager, minimal attack surface
```

The `distroless/static` image has no shell (`sh`, `bash`). That's intentional: a shell in the runtime image is an attacker's foothold after a container escape. The tradeoff is that `kubectl exec` into the manager pod gives nothing useful — use ephemeral debug containers for live diagnosis (`kubectl debug -it <pod> --image=busybox --target=manager`).

## Step 3 — Load to kind

```bash
kind load docker-image widget-controller:dev --name dojo
```

**This is the single most common mistake when first shipping to kind.** kind node containers have an isolated CRI image store — completely separate from your host Docker. A `docker build` result never reaches the nodes automatically. `kind load` copies the image tar into every node's containerd store.

Confirm the load worked:

```bash
docker exec dojo-control-plane crictl images | grep widget-controller
```

If you skip this step, the pod will get `ErrImagePull` or `ImagePullBackOff` even though `docker images` shows the image on your host.

Why `imagePullPolicy: IfNotPresent` in the Deployment manifest matters: the default for an unqualified tag is `IfNotPresent`, but be explicit. `Always` would cause the node to try pulling from a registry — which fails for a locally-loaded image with no push destination. `Never` would work too but prevents pulling from a real registry if you change the image reference.

## Step 4 — Create namespace and apply manifests

```bash
kubectl create namespace dojo-operator --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f config/crd/
kubectl wait --for=condition=Established crd/widgets.dojo.dev --timeout=30s
kubectl apply -f config/rbac/
kubectl apply -f config/manager/
```

**Why the order matters:**

1. **Namespace first.** The RBAC ServiceAccount and the manager Deployment both reference `dojo-operator`. If the namespace doesn't exist, `kubectl apply -f config/rbac/` fails immediately.
2. **CRD before operator.** If the operator starts before the CRD is Established, `ctrl.NewControllerManagedBy(mgr).For(&Widget{})` fails on startup because the API server doesn't yet know about the `dojo.dev/v1` group. The operator crash-loops until the CRD appears. `kubectl wait --for=condition=Established` blocks the script until the CRD is fully registered.
3. **RBAC before Deployment.** The manager pod runs as the `widget-controller-manager` ServiceAccount. If the ClusterRoleBinding doesn't exist, every `r.Get` and `r.Create` returns 403, and the controller logs `"Forbidden"` on every reconcile cycle.

## Step 5 — Verify the controller is Running

```bash
kubectl -n dojo-operator rollout status deployment/widget-controller-manager --timeout=90s
kubectl -n dojo-operator get pods
kubectl -n dojo-operator logs deployment/widget-controller-manager
```

You should see log lines like:
```
INFO    Starting manager
INFO    Starting workers    {"controller": "widget", "worker count": 1}
```

## Step 6 — Create a sample Widget

```bash
kubectl apply -f - << 'EOF'
apiVersion: dojo.dev/v1
kind: Widget
metadata:
  name: sample
  namespace: dojo-operator
spec:
  replicas: 1
  image: nginx:1.27-alpine
EOF
```

Watch the controller reconcile it:

```bash
kubectl -n dojo-operator logs deployment/widget-controller-manager -f
kubectl -n dojo-operator get deployments
```

You should see a `widget-sample` Deployment appear. That's the reconcile loop from challenge 04, running live.

## Attacker's view

The manager's ServiceAccount has `get/list/watch` over all Widgets and can `create/update/patch` Deployments cluster-wide (ClusterRole, not Role). In a production operator you would scope this to specific namespaces via a Role + RoleBinding, or use a generated manifest from `controller-gen` that scopes permissions exactly. A ClusterRole with broad `deployments` verbs is a significant privilege escalation vector if the manager pod is compromised — an attacker could create a privileged DaemonSet on every node.

## Cleanup

```bash
kubectl delete namespace dojo-operator
kubectl delete crd widgets.dojo.dev
kubectl delete clusterrole widget-controller-manager-role
kubectl delete clusterrolebinding widget-controller-manager-rolebinding
```
