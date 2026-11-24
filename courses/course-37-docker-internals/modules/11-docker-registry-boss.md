# Run Your Own Docker Registry

> **Module 11 · Course 37** — Every `docker push` and `docker pull` talks to a registry. Docker Hub, GHCR, ECR — they all implement the same open standard: the OCI Distribution Specification. This module shows you exactly how that protocol works, runs a production-capable registry with authentication, connects it to a kind cluster, and covers Harbor for teams who need more. This is the boss module.

---

## What Is a Registry?

A Docker registry is a **content-addressed HTTP store** for two things:
1. **Manifests** — JSON documents describing an image (list of layer digests + config)
2. **Blobs** — the actual layer tarballs and config JSON, referenced by sha256 digest

That's it. The entire complexity of Docker image distribution comes down to: store blobs by digest, store manifests by name+tag, and handle auth.

```
Registry stores:
  /v2/myapp/manifests/1.0        → manifest (JSON, describes layers)
  /v2/myapp/blobs/sha256:abc...  → layer blob (compressed tarball)
  /v2/myapp/blobs/sha256:def...  → config blob (image metadata JSON)
```

---

## The OCI Distribution Spec: The HTTP API

The [OCI Distribution Specification](https://github.com/opencontainers/distribution-spec) defines the exact API every registry must implement. Let's explore it with curl:

```bash
# Start a local registry
docker run -d -p 5000:5000 --name registry-demo registry:2.8.3

# 1. /v2/ — The ping endpoint. Returns 200 if the registry works (401 if auth required)
curl -s http://localhost:5000/v2/
# {}   ← empty JSON, means it's working

# 2. Push an image to our registry
docker tag nginx:1.27-alpine localhost:5000/my-nginx:1.27
docker push localhost:5000/my-nginx:1.27

# 3. List tags for a repository
curl -s http://localhost:5000/v2/my-nginx/tags/list
# {"name":"my-nginx","tags":["1.27"]}

# 4. Get the manifest (what layers make up this image)
curl -s \
  -H "Accept: application/vnd.oci.image.manifest.v1+json" \
  http://localhost:5000/v2/my-nginx/manifests/1.27 | python3 -m json.tool
# {
#   "schemaVersion": 2,
#   "mediaType": "application/vnd.docker.distribution.manifest.v2+json",
#   "config": {
#     "mediaType": "application/vnd.docker.container.image.v1+json",
#     "size": 7682,
#     "digest": "sha256:abcdef..."
#   },
#   "layers": [
#     { "mediaType": "...", "size": 3109268, "digest": "sha256:111aaa..." },
#     { "mediaType": "...", "size": 1234567, "digest": "sha256:222bbb..." }
#   ]
# }

# 5. Download a specific blob (layer) by digest
DIGEST="sha256:111aaa..."  # get from manifest above
curl -s -L \
  http://localhost:5000/v2/my-nginx/blobs/$DIGEST \
  -o layer.tar.gz
tar -tzf layer.tar.gz | head -10  # see what files are in this layer

docker rm -f registry-demo
```

---

## The Push Flow: What Happens on docker push

When you `docker push`, here's the HTTP sequence:

```
docker push localhost:5000/my-app:1.0
    │
    ├── 1. HEAD /v2/my-app/blobs/<digest>
    │      → 200: blob already exists (skip upload)
    │      → 404: need to upload
    │
    ├── 2. POST /v2/my-app/blobs/uploads/
    │      → 202: returns Location header with upload UUID
    │
    ├── 3. PATCH /v2/my-app/blobs/uploads/<uuid>
    │      → stream the layer bytes (chunked upload)
    │      → 202: upload in progress
    │
    ├── 4. PUT /v2/my-app/blobs/uploads/<uuid>?digest=sha256:...
    │      → finalize the upload, verify digest
    │      → 201: blob stored
    │
    └── 5. PUT /v2/my-app/manifests/1.0
           → push the manifest that references all layer blobs
           → 201: image complete
```

```
docker pull localhost:5000/my-app:1.0
    │
    ├── 1. GET /v2/my-app/manifests/1.0  → get manifest (layer digests)
    │
    ├── 2. For each layer digest:
    │      HEAD /v2/my-app/blobs/<digest>  → check if cached
    │      GET  /v2/my-app/blobs/<digest>  → download if not cached
    │
    └── 3. Unpack and assemble layers into OverlayFS
```

---

## Run registry:2 Locally (No Auth)

```bash
# Simple registry — no auth, no TLS
docker run -d \
  -p 5000:5000 \
  --name my-registry \
  --restart=unless-stopped \
  registry:2.8.3

# Push and pull
docker tag nginx:1.27-alpine localhost:5000/my-nginx:1.27
docker push localhost:5000/my-nginx:1.27

# Pull it back (after removing local copy)
docker rmi localhost:5000/my-nginx:1.27
docker pull localhost:5000/my-nginx:1.27

# See all repositories
curl -s http://localhost:5000/v2/_catalog
# {"repositories":["my-nginx"]}
```

---

## Add htpasswd Authentication

For a registry others will push to, you need authentication:

```bash
# Step 1: Generate credentials with htpasswd
# Using Docker to run htpasswd (avoids installing it)
docker run --rm \
  httpd:2.4 \
  htpasswd -Bbn dojo docker-master > /tmp/htpasswd

cat /tmp/htpasswd
# dojo:$2y$05$...  ← bcrypt-hashed password

# Step 2: Run registry with htpasswd auth
docker run -d \
  -p 5000:5000 \
  --name my-auth-registry \
  -v /tmp/htpasswd:/auth/htpasswd:ro \
  -e REGISTRY_AUTH=htpasswd \
  -e "REGISTRY_AUTH_HTPASSWD_REALM=Dojo Registry" \
  -e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd \
  registry:2.8.3

# Step 3: Verify auth is required
curl -s http://localhost:5000/v2/
# {"errors":[{"code":"UNAUTHORIZED","message":"authentication required",...}]}

# Step 4: Login
docker login localhost:5000
# Username: dojo
# Password: docker-master
# Login Succeeded

# Step 5: Push
docker tag nginx:1.27-alpine localhost:5000/dojo-nginx:1.27
docker push localhost:5000/dojo-nginx:1.27

# Credentials are stored in ~/.docker/config.json
cat ~/.docker/config.json
# {"auths":{"localhost:5000":{"auth":"...base64 encoded..."}}}

docker rm -f my-auth-registry
```

---

## Add TLS (Production-Grade)

A registry without TLS sends credentials in base64 (effectively plaintext). For production:

```bash
# Step 1: Generate a self-signed cert (for testing)
mkdir -p /tmp/registry-certs
openssl req -newkey rsa:4096 -nodes \
  -keyout /tmp/registry-certs/domain.key \
  -x509 -days 365 \
  -out /tmp/registry-certs/domain.crt \
  -subj "/CN=localhost" \
  -addext "subjectAltName=IP:127.0.0.1,DNS:localhost"

# Step 2: Run registry with TLS
docker run -d \
  -p 5443:5000 \
  --name my-tls-registry \
  -v /tmp/registry-certs:/certs:ro \
  -v /tmp/htpasswd:/auth/htpasswd:ro \
  -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/domain.crt \
  -e REGISTRY_HTTP_TLS_KEY=/certs/domain.key \
  -e REGISTRY_AUTH=htpasswd \
  -e "REGISTRY_AUTH_HTPASSWD_REALM=Secure Dojo Registry" \
  -e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd \
  registry:2.8.3

# Step 3: Trust the cert (for testing self-signed)
sudo cp /tmp/registry-certs/domain.crt /etc/docker/certs.d/localhost:5443/ca.crt
# (Creates a per-registry trust override)

# Or use insecure-registries in /etc/docker/daemon.json (dev only):
# { "insecure-registries": ["localhost:5443"] }

docker login https://localhost:5443
docker push localhost:5443/secure-app:1.0
docker rm -f my-tls-registry
```

---

## Connect kind to Your Local Registry

kind nodes have their own containerd image store. By default, they don't trust insecure local registries. Here's how to wire it up properly using kind's `containerdConfigPatches`:

```yaml
# kind-with-registry.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
containerdConfigPatches:
- |-
  [plugins."io.containerd.grpc.v1.cri".registry]
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors]
      [plugins."io.containerd.grpc.v1.cri".registry.mirrors."localhost:5000"]
        endpoint = ["http://host-gateway:5000"]
    [plugins."io.containerd.grpc.v1.cri".registry.configs]
      [plugins."io.containerd.grpc.v1.cri".registry.configs."host-gateway:5000".auth]
        username = "dojo"
        password = "docker-master"
```

```bash
# Start a local registry (must be running before kind cluster)
docker run -d -p 5000:5000 --name kind-registry registry:2.8.3

# Create cluster with registry config
kind create cluster --config kind-with-registry.yaml --name dojo

# Push an image to your local registry
docker tag nginx:1.27-alpine localhost:5000/my-app:1.0
docker push localhost:5000/my-app:1.0

# Deploy a pod that pulls from your registry
kubectl run my-app --image=localhost:5000/my-app:1.0
kubectl get pods
# my-app   1/1   Running   0   15s

# It pulled from your local registry!
kubectl describe pod my-app | grep Image
# Image: localhost:5000/my-app:1.0
```

---

## Registry Configuration Options

The `registry:2` image reads environment variables or a config YAML:

```yaml
# /etc/docker/registry/config.yml
version: 0.1
log:
  level: info
storage:
  filesystem:
    rootdirectory: /var/lib/registry
  delete:
    enabled: true        # allow deleting images
  cache:
    blobdescriptor: inmemory
http:
  addr: :5000
auth:
  htpasswd:
    realm: "Dojo Registry"
    path: /auth/htpasswd
health:
  storagedriver:
    enabled: true
    interval: 10s
    threshold: 3
```

```bash
# Run with custom config
docker run -d -p 5000:5000 \
  -v /path/to/config.yml:/etc/docker/registry/config.yml:ro \
  registry:2.8.3
```

---

## Harbor: Production-Grade Registry

`registry:2` is the reference implementation — simple but limited. For teams, [Harbor](https://goharbor.io) adds:

- **Web UI** — browse images, see vulnerability scan results
- **Role-based access control** (RBAC) — users, groups, project-level permissions
- **Image scanning** — integrated Trivy/Clair scanning on push
- **Replication** — sync images to/from other registries
- **Proxy cache** — cache Docker Hub images to avoid pull rate limits
- **Webhooks** — trigger CI on push
- **Image retention policies** — auto-delete old tags
- **Robot accounts** — machine tokens for CI/CD

```bash
# Harbor is Helm-deployable on Kubernetes
helm repo add harbor https://helm.goharbor.io
helm install harbor harbor/harbor \
  --set expose.type=nodePort \
  --set expose.tls.enabled=false \
  --set externalURL=http://localhost:30002 \
  --set harborAdminPassword=Harbor12345

kubectl get pods -n default | grep harbor
```

Harbor is the standard choice when you need more than a basic registry.

---

## Image Signing with Cosign (Preview)

The OCI Referrers API (a newer extension to the Distribution Spec) allows attaching metadata to images — including **signatures**.

```bash
# Install cosign
brew install cosign  # macOS

# Generate a key pair
cosign generate-key-pair
# cosign.key (private — keep this safe)
# cosign.pub (public)

# Sign an image in a registry
cosign sign --key cosign.key localhost:5000/my-app:1.0

# Verify the signature
cosign verify --key cosign.pub localhost:5000/my-app:1.0

# The signature is stored as a separate OCI artifact, referenced by digest:
# localhost:5000/my-app:sha256-<digest>.sig
curl -s http://localhost:5000/v2/my-app/referrers/<digest>
```

This is covered in Challenge 13 — Image Signing.

---

## Checkpoint

1. What are the two types of objects a Docker registry stores?
2. What HTTP method and endpoint starts a blob upload? What does it return?
3. What does the `PUT /v2/<name>/manifests/<tag>` call do, and why does it happen last?
4. What is the difference between `registry:2` and Harbor? Name three features Harbor adds.
5. How do you configure kind to pull images from a local insecure registry?
6. What does `docker login` store, and where does it store it?
7. What is htpasswd and what hashing algorithm does the `-B` flag use?
8. Why should a production registry use TLS? What can happen without it?
9. What is the OCI Referrers API used for in the context of image signing?
10. What endpoint returns the list of all repositories in a registry?

---

## Course Complete

You've covered the full Docker stack from bottom to top:

| Module | Topic |
|--------|-------|
| 01 | How Docker works (daemon → containerd → runc) |
| 02 | Linux namespaces (the isolation mechanism) |
| 03 | cgroups (the resource control mechanism) |
| 04 | OverlayFS (the filesystem mechanism) |
| 05 | Dockerfile mastery (ARG/ENV, shell/exec form, BuildKit secrets) |
| 06 | Multi-stage builds and minimal images |
| 07 | Docker networking (veth pairs, bridges, iptables) |
| 08 | Volumes and storage |
| 09 | Container security (capabilities, seccomp, AppArmor) |
| 10 | Build your own container runtime from scratch |
| 11 | Run your own Docker registry |

Now apply this knowledge in the 15 challenges. The boss challenge (#15 Registry Boss) ties it all together.
