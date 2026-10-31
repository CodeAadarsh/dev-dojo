# Solution — Deploy API to kind

The flag is `KUBE{ship_it_to_kind}`.

## Step 1 — edit deploy.yaml

Replace `FILL_IN` with the image tag:

```yaml
          image: dojo-api:v1
          imagePullPolicy: IfNotPresent
```

## Step 2 — build the image

```bash
cd $HOME/.kube-dojo-work/06-deploy-api-to-kind
docker build -t dojo-api:v1 .
```

## Step 3 — load into kind

```bash
kind load docker-image dojo-api:v1 --name dojo
```

This copies the image into every node's containerd image store. Confirm it arrived:

```bash
docker exec dojo-control-plane crictl images | grep dojo-api
```

## Step 4 — apply the manifest

```bash
kubectl apply -f $HOME/.kube-dojo-work/06-deploy-api-to-kind/deploy.yaml
kubectl -n dojo-backend rollout status deploy/dojo-api
kubectl -n dojo-backend get deploy,pod,svc
```

## Step 5 — run the verifier

```bash
bash courses/course-10-backend-engineering/challenges/06-deploy-api-to-kind/verify.sh
```

## Why each piece is critical

**`kind load` after every build**  
A kind cluster maintains a separate containerd image store inside each node container — completely separate from your host Docker daemon. `kind load docker-image` copies the compressed image layers into every node. If you skip this (or do it before building), kubelet will look inside the node, find nothing, and try a registry pull. `dojo-api:v1` does not exist on Docker Hub, so the pod enters `ImagePullBackOff` and never starts.

**`imagePullPolicy: IfNotPresent`**  
For images without a digest (`@sha256:...`), kubelet's default is `IfNotPresent` for tags other than `:latest`. For `:latest` the default is `Always`. Since we pinned to `dojo-api:v1`, the default would be `IfNotPresent` anyway — but making it explicit is the right habit for kind workflows, documents the intent, and prevents surprises if someone later changes the tag to `:latest`.

**`host="0.0.0.0"` in Flask**  
`app.run(host="0.0.0.0")` binds to all interfaces inside the container, making the port reachable from the pod's network interface. `127.0.0.1` (the default if you omit `host=`) binds only to loopback — nothing outside the container process can connect, so port-forward, the readiness probe, and the Service all see connection refused.

**`readinessProbe`**  
A readiness probe on `/healthz` tells kubelet when the pod is actually ready to receive traffic. Without it the pod is marked ready immediately after the container starts, before Flask has finished its startup sequence. During a rolling update, traffic can be sent to a pod that is technically running but not yet listening.

## What changes in a real CI/CD pipeline

```bash
# build + tag for a registry
docker build -t my-registry.io/myteam/dojo-api:$(git rev-parse --short HEAD) .
docker push my-registry.io/myteam/dojo-api:<sha>

# Deployment uses the registry tag; no kind load needed
# imagePullPolicy defaults to IfNotPresent for pinned tags
```

In production you push to a container registry (ECR, GCR, ACR, Docker Hub) and the cluster pulls from there. `imagePullSecrets` on the `ServiceAccount` or the Pod spec provides registry credentials. The `kind load` step exists only because kind nodes cannot reach your laptop's Docker daemon — it is a local-dev-only workaround.
