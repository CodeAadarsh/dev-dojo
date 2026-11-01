# Solution — Dockerize and Deploy to Kubernetes

## Complete Dockerfile

```dockerfile
# ── Stage 1: build ────────────────────────────────────────────────────────────
FROM node:20-alpine AS builder
WORKDIR /app

COPY package.json package-lock.json* ./
RUN npm ci

COPY tsconfig.json ./
COPY src/ ./src/
RUN npm run build

# ── Stage 2: runtime ──────────────────────────────────────────────────────────
FROM node:20-alpine AS runtime
WORKDIR /app

# Copy only production deps and compiled output from builder
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/dist ./dist
COPY --from=builder /app/package.json ./

# Fix ownership so the node user can read the files
RUN chown -R node:node /app

# node:20-alpine ships a 'node' user at uid 1000 — use it
USER node

ENV PORT=3000
EXPOSE 3000

CMD ["node", "dist/index.js"]
```

## Kubernetes manifests

```yaml
# deploy.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: dojo-node
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dojo-node-api
  namespace: dojo-node
spec:
  replicas: 1
  selector:
    matchLabels:
      app: dojo-node-api
  template:
    metadata:
      labels:
        app: dojo-node-api
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
      containers:
        - name: api
          image: dojo-node-api:1.0.0
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 3000
          env:
            - name: PORT
              value: "3000"
          readinessProbe:
            httpGet:
              path: /health
              port: 3000
            initialDelaySeconds: 5
            periodSeconds: 5
            failureThreshold: 3
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
---
apiVersion: v1
kind: Service
metadata:
  name: dojo-node-api
  namespace: dojo-node
spec:
  selector:
    app: dojo-node-api
  ports:
    - port: 80
      targetPort: 3000
  type: ClusterIP
```

## Full deployment sequence

```bash
# 1. Build
cd ~/.kube-dojo-work/06-dockerize-and-deploy
docker build -t dojo-node-api:1.0.0 .

# 2. Verify the image runs locally (quick sanity check)
docker run --rm -p 3001:3000 dojo-node-api:1.0.0 &
curl http://localhost:3001/health   # should return {"status":"ok"}
kill %1

# 3. Load into kind (every node's image store)
kind load docker-image dojo-node-api:1.0.0 --name dojo

# 4. Apply manifests
kubectl apply -f deploy.yaml

# 5. Watch rollout
kubectl rollout status deployment/dojo-node-api -n dojo-node

# 6. Smoke test inside the cluster
kubectl run tmp --rm -it -n dojo-node --image=curlimages/curl:8.6.0 \
  --restart=Never -- curl http://dojo-node-api/health

# 7. Verify
bash courses/course-33-node-backend-scale/challenges/06-dockerize-and-deploy/verify.sh
```

## Why each piece is required

**Multi-stage build.**
Without multiple stages, your image would include TypeScript, `ts-node`, `@types/*`, and all dev dependencies — adding ~150 MB to a production image. The builder stage compiles; the runtime stage copies only `dist/` and production `node_modules`. The final image is ~80 MB vs ~300 MB single-stage.

**`npm ci` over `npm install` in the build stage.**
`npm ci` requires `package-lock.json` and installs exactly the locked versions — no resolution, no drift. It also deletes `node_modules` first, making it reproducible. This is the correct command for any CI/CD or Dockerfile build.

**`USER node` + `chown -R node:node /app`.**
The `node:20-alpine` image ships a `node` user at uid 1000. Without `chown`, the files are owned by root, and `USER node` causes permission-denied errors at runtime. The `chown` runs as root (before `USER node`), transfers ownership, then `USER node` drops privileges.

**`imagePullPolicy: IfNotPresent`.**
Without this, Kubernetes tries to pull `dojo-node-api:1.0.0` from Docker Hub (which has no such image) and fails with `ErrImagePull`. `IfNotPresent` tells the kubelet: "if the image is already in the node's cache, use it." The `kind load` step put it in the cache.

**`readinessProbe` on `/health`.**
Without a readiness probe, Kubernetes marks the pod Ready as soon as the container process starts — before Express is listening. Requests can arrive and get connection-refused. The readiness probe polls `/health`; only when it returns 2xx does the pod join the load balancer. `initialDelaySeconds: 5` gives Express time to bind.

**`securityContext.runAsNonRoot: true`.**
This is a pod-level admission control: if the container image's USER is root (uid 0), the pod will not start. It acts as a safety net even if someone accidentally changes `USER` in the Dockerfile. Pair with `runAsUser: 1000` to be explicit.

## Attacker's view

A root container in Kubernetes is one kernel exploit away from owning the node. Even without an exploit, root inside the container can write to any mounted volume, mess with other processes via `/proc`, and potentially escape into the host namespace in a misconfigured cluster. `runAsNonRoot` at the pod spec level is enforced by the kubelet, not the container — it cannot be bypassed from inside the container.
