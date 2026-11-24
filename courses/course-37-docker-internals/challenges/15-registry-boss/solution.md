# Solution: Registry Boss

This is a multi-step challenge. Take it step by step.

## Step 1: Generate htpasswd credentials

`registry:2.8.3` supports HTTP Basic authentication via an `htpasswd` file. Use `bcrypt` hashing (`-B` flag):

```bash
docker run --rm httpd:2.4 htpasswd -Bbn dojo docker-master > /tmp/registry-htpasswd
cat /tmp/registry-htpasswd
# dojo:$2y$05$...hashed...
```

## Step 2: Create the auth Secret

```bash
kubectl create secret generic registry-auth \
  --from-file=htpasswd=/tmp/registry-htpasswd \
  -n dojo-docker-registry \
  --dry-run=client -o yaml | kubectl apply -f -
```

## Step 3: Deploy the registry

```yaml
# Save as registry-deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: registry
  namespace: dojo-docker-registry
  annotations:
    dojo.docker/registry-verified: "true"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: registry
  template:
    metadata:
      labels:
        app: registry
    spec:
      containers:
      - name: registry
        image: registry:2.8.3
        ports:
        - containerPort: 5000
        env:
        - name: REGISTRY_AUTH
          value: htpasswd
        - name: REGISTRY_AUTH_HTPASSWD_REALM
          value: "Dojo Private Registry"
        - name: REGISTRY_AUTH_HTPASSWD_PATH
          value: /auth/htpasswd
        volumeMounts:
        - name: auth
          mountPath: /auth
          readOnly: true
      volumes:
      - name: auth
        secret:
          secretName: registry-auth
```

```bash
kubectl apply -f registry-deployment.yaml
kubectl rollout status deployment registry -n dojo-docker-registry
```

## Step 4: Create the Service

```yaml
# Save as registry-service.yaml
apiVersion: v1
kind: Service
metadata:
  name: registry-svc
  namespace: dojo-docker-registry
spec:
  selector:
    app: registry
  ports:
  - port: 5000
    targetPort: 5000
  type: ClusterIP
```

```bash
kubectl apply -f registry-service.yaml
```

## Step 5: Port-forward and push an image

The registry is a ClusterIP service — only reachable inside the cluster. Port-forward to push from your host:

```bash
kubectl port-forward -n dojo-docker-registry svc/registry-svc 5000:5000 &
PF_PID=$!
sleep 2

# Allow Docker to use this HTTP (not HTTPS) registry
# macOS Docker Desktop: Preferences → Docker Engine → add to "insecure-registries"
# Or add to /etc/docker/daemon.json: {"insecure-registries": ["localhost:5000"]}
# Then restart Docker.

docker login localhost:5000 -u dojo -p docker-master

docker tag nginx:1.27-alpine localhost:5000/dojo/nginx:1.27
docker push localhost:5000/dojo/nginx:1.27

kill $PF_PID 2>/dev/null || true
```

Verify the push worked:

```bash
kubectl port-forward -n dojo-docker-registry svc/registry-svc 5000:5000 &
sleep 1
curl -u dojo:docker-master http://localhost:5000/v2/dojo/nginx/tags/list
# {"name":"dojo/nginx","tags":["1.27"]}
kill %1 2>/dev/null || true
```

## Step 6: Create imagePullSecrets

The kubelet on a kind node needs credentials to pull from the registry. Create a `docker-registry` Secret:

```bash
kubectl create secret docker-registry registry-pull-secret \
  --docker-server=registry-svc.dojo-docker-registry.svc.cluster.local:5000 \
  --docker-username=dojo \
  --docker-password=docker-master \
  -n dojo-docker-registry \
  --dry-run=client -o yaml | kubectl apply -f -
```

> **kind + insecure registry:** kind nodes run containerd. For containerd to allow an HTTP (non-TLS) registry, you need to configure it. The simplest approach for this lab is to use a NodePort service and configure kind at cluster creation time. Alternatively, configure containerd on each kind node:
>
> ```bash
> # On each kind node
> docker exec dojo-control-plane bash -c '
> mkdir -p /etc/containerd/certs.d/registry-svc.dojo-docker-registry.svc.cluster.local:5000
> cat > /etc/containerd/certs.d/registry-svc.dojo-docker-registry.svc.cluster.local:5000/hosts.toml <<EOF
> [host."http://registry-svc.dojo-docker-registry.svc.cluster.local:5000"]
>   capabilities = ["pull","resolve"]
>   skip_verify = true
> EOF
> '
> ```

## Step 7: Deploy the consumer pod

```yaml
# Save as registry-consumer.yaml
apiVersion: v1
kind: Pod
metadata:
  name: registry-consumer
  namespace: dojo-docker-registry
spec:
  imagePullSecrets:
  - name: registry-pull-secret
  containers:
  - name: app
    image: registry-svc.dojo-docker-registry.svc.cluster.local:5000/dojo/nginx:1.27
    imagePullPolicy: Always
```

```bash
kubectl apply -f registry-consumer.yaml
kubectl wait pod registry-consumer -n dojo-docker-registry --for=condition=Ready --timeout=60s
```

## Step 8: Annotate and verify

```bash
kubectl annotate deployment registry \
  dojo.docker/registry-verified=true \
  -n dojo-docker-registry

bash courses/course-37-docker-internals/challenges/15-registry-boss/verify.sh
```

## What you built

You implemented the full OCI Distribution Spec stack:

- **Storage**: the registry Pod stores image manifests and blobs in its container filesystem (emptyDir in this lab; a PVC in production)
- **Auth**: the htpasswd file is the user database; `registry:2.8.3` handles Bearer token auth internally
- **Push path**: your laptop → port-forward → Service → registry Pod → stores blobs
- **Pull path**: kubelet on kind node → Service DNS → registry Pod → returns blobs → containerd unpacks layers → pod starts

This is the same architecture used by Harbor, Artifactory, and GitHub Container Registry — just without the UI, replication, and scanning layers on top.

## Production hardening (what comes next)

| Feature | How |
|---|---|
| TLS | Mount a TLS cert Secret; set `REGISTRY_HTTP_TLS_CERTIFICATE` and `REGISTRY_HTTP_TLS_KEY` |
| Persistent storage | Use a PVC instead of emptyDir |
| Image vulnerability scanning | Harbor adds Trivy scanning on every push |
| Replication | Harbor can replicate to/from other registries |
| Admission control | Use Kyverno to block pods that pull from unapproved registries |
