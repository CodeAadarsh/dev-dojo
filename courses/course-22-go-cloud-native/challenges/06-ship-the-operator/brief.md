# Ship the Operator

The Widget controller has passed all unit tests. Your tech lead has approved the PR. The comment on the merge: *"Great work — now ship it. Build the image, load it into the dojo cluster, apply the CRD and RBAC, bring up the manager. Show me `ESTABLISHED` and `Running`."*

This is the bridge challenge: everything you built in challenges 04 and 05 lands in a live kind cluster.

## Prerequisites

- Docker Desktop running
- kind cluster `dojo` running (`kubectl config current-context` → `kind-dojo`)
- Go 1.22+ installed

## Context

`setup.sh` plants a complete, ready-to-build Go operator in your work directory:

```
~/.kube-dojo-work/06-ship-the-operator/
├── go.mod              # widget-operator module
├── main.go             # single-file operator: Widget types + Reconciler + main()
├── Dockerfile          # multi-stage build: golang:1.22-alpine → distroless
└── config/
    ├── crd/
    │   └── widget-crd.yaml    # CRD for widgets.dojo.dev/v1
    ├── rbac/
    │   └── rbac.yaml          # ServiceAccount, ClusterRole, ClusterRoleBinding
    └── manager/
        └── manager.yaml       # Deployment for the controller manager
```

You do **not** need to modify any Go code. The operator is complete and correct. Your mission is the deployment workflow.

## Mission

Execute these steps in order:

```bash
cd ~/.kube-dojo-work/06-ship-the-operator

# 1. Fetch Go dependencies
go mod tidy

# 2. Build the operator image
docker build -t widget-controller:dev .

# 3. Load the image into every kind node (kind nodes never pull from host Docker)
kind load docker-image widget-controller:dev --name dojo

# 4. Create the operator namespace
kubectl create namespace dojo-operator --dry-run=client -o yaml | kubectl apply -f -

# 5. Apply the CRD (wait for it to be Established)
kubectl apply -f config/crd/
kubectl wait --for=condition=Established crd/widgets.dojo.dev --timeout=30s

# 6. Apply RBAC
kubectl apply -f config/rbac/

# 7. Deploy the controller manager
kubectl apply -f config/manager/

# 8. Confirm the controller is running
kubectl -n dojo-operator rollout status deployment/widget-controller-manager --timeout=90s
```

The verify script checks exactly two conditions:

1. CRD `widgets.dojo.dev` has condition `Established=True`.
2. Deployment `widget-controller-manager` in namespace `dojo-operator` has `readyReplicas >= 1`.

## Why this matters

Building and running an operator in CI is different from running it in a test. Three things trip everyone up on first ship:

- **`kind load docker-image`** — kind nodes are containers on your host. They have an isolated image store, completely separate from your host Docker. A locally-built image is invisible to the cluster until you explicitly load it. `imagePullPolicy: IfNotPresent` prevents the node from trying to pull an image it already has; omitting it causes `ErrImagePull`.
- **CRD lifecycle** — applying a CRD does not instantly make it queryable. The API server must re-discover the new group/version/resource and validate the schema. `kubectl wait --for=condition=Established` blocks until this is complete; without it, the operator may start before the API server accepts Widget objects and crash-loop immediately.
- **RBAC order** — the manager Deployment references a ServiceAccount. Apply RBAC before the Deployment or the pod starts with no permissions and every reconcile returns a 403.

## Verify

```bash
bash courses/course-22-go-cloud-native/challenges/06-ship-the-operator/verify.sh
```

CRD Established + controller Deployment running → flag printed.

## Cleanup

```bash
kubectl delete namespace dojo-operator
kubectl delete crd widgets.dojo.dev
kubectl delete clusterrole widget-controller-manager-role
kubectl delete clusterrolebinding widget-controller-manager-rolebinding
```
