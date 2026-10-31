# Solution — Ship From Your Own Registry

## Step 0 — stand up the registry (once)

```bash
bash labs/bootstrap/install-registry.sh
```

Confirm it's up and reachable from your host:

```bash
docker ps --filter name=kind-registry
curl -s http://localhost:5001/v2/_catalog ; echo
# -> {"repositories":[]}   (empty until you push)
```

## Step 1–3 — the build/tag/push loop

For this challenge we don't even need a custom Dockerfile — retagging a public image exercises the exact same path:

```bash
docker pull nginx:1.27-alpine
docker tag  nginx:1.27-alpine localhost:5001/web:v1
docker push localhost:5001/web:v1
```

Prove the artifact is now in *your* repository, not Docker Hub:

```bash
curl -s http://localhost:5001/v2/_catalog ; echo
# -> {"repositories":["web"]}
curl -s http://localhost:5001/v2/web/tags/list ; echo
# -> {"name":"web","tags":["v1"]}
```

## Step 4 — deploy from the local registry

```bash
kubectl -n dojo-registry create deployment web \
  --image=localhost:5001/web:v1 --replicas=1
kubectl -n dojo-registry rollout status deploy/web
```

Or declaratively (preferred — note `imagePullPolicy: IfNotPresent` so a cached layer doesn't force a re-pull you don't need):

```yaml
# web.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: dojo-registry
  labels:
    app: web
spec:
  replicas: 1
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
        - name: web
          image: localhost:5001/web:v1
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 80
```

```bash
kubectl apply -f web.yaml
kubectl -n dojo-registry rollout status deploy/web
bash courses/course-05-internals-cluster-repo/challenges/04-local-registry-deploy/verify.sh
```

## Why the `localhost:5001` string works on both sides

This is the part that trips everyone up, so make it explicit:

- On your **host**, `localhost:5001` hits the published port of the `kind-registry` container — that's what `docker push` talks to.
- On each **node**, `install-registry.sh` wrote `/etc/containerd/certs.d/localhost:5001/hosts.toml` pointing at `http://kind-registry:5000`. So when the kubelet asks containerd to pull `localhost:5001/web:v1`, containerd rewrites that to the registry container over the shared `kind` Docker network.

Same image string in the `docker push` and in the manifest — resolved correctly in two different network namespaces. That symmetry is the whole trick of the kind local-registry pattern.

## The one-off alternative

If you just want a locally-built image on the nodes and don't care about a registry:

```bash
docker build -t web:v1 .
kind load docker-image web:v1 --name dojo
# then reference image: web:v1 with imagePullPolicy: IfNotPresent
```

`kind load` copies the image tarball into every node's containerd store directly. It's faster for a single image but doesn't teach you anything about registries, and it won't satisfy *this* verifier (which looks for a `localhost:5001/` path) — it's the tool you reach for when you're iterating on one image, not shipping.

## When it won't pull — fast triage

| Symptom (`kubectl -n dojo-registry describe pod ...`) | Cause | Fix |
|---|---|---|
| `ErrImagePull: ... connection refused` to `localhost:5001` | registry container not running / not on the `kind` network | re-run `install-registry.sh`; `docker network inspect kind \| grep kind-registry` |
| `manifest unknown` / `not found` | you built & tagged but never `docker push`ed, or wrong tag | `curl -s localhost:5001/v2/web/tags/list` — if your tag isn't listed, push it |
| `http: server gave HTTP response to HTTPS client` | node trying TLS to a plain-HTTP registry (missing `hosts.toml`) | ensure `install-registry.sh` ran *after* the cluster was created so the `certs.d` file exists on every node |
