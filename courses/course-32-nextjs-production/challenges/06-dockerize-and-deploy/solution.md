# Solution: Dockerize and Deploy

## 1. Complete the Dockerfile

```dockerfile
# Stage 1: builder
FROM node:20-alpine AS builder
WORKDIR /app

COPY package.json package-lock.json* ./
RUN npm ci

COPY . .
RUN npm run build

# Stage 2: runner
FROM node:20-alpine AS runner
WORKDIR /app

ENV NODE_ENV=production
ENV PORT=3000
ENV HOSTNAME=0.0.0.0

# Copy the standalone output — this is the self-contained server
COPY --from=builder /app/.next/standalone ./
# Static assets must be placed where the standalone server expects them
COPY --from=builder /app/.next/static ./.next/static
# Public assets (if any)
COPY --from=builder /app/public ./public

EXPOSE 3000
CMD ["node", "server.js"]
```

### Why this specific copy pattern

`next build` with `output: 'standalone'` produces three things you need:

| Source | Destination | Contents |
|---|---|---|
| `.next/standalone/` | `/app/` | `server.js` + a trimmed `node_modules/` with only runtime deps |
| `.next/static/` | `/app/.next/static/` | Hashed JS/CSS chunks, served by the standalone server |
| `public/` | `/app/public/` | Images, fonts, robots.txt — served directly |

Missing either of the last two means the app boots but serves 404s for all assets. This is the most common Dockerfile mistake for Next.js apps.

## 2. Build the image

```bash
cd ~/.kube-dojo-work/06-dockerize-and-deploy
npm install      # needed for the build stage — or let Docker handle it
docker build -t dojo-nextjs:v1 .
```

Confirm it runs locally before touching the cluster:

```bash
docker run --rm -p 3000:3000 dojo-nextjs:v1
curl http://localhost:3000/api/health   # -> {"status":"ok"}
```

## 3. Load into kind

```bash
kind load docker-image dojo-nextjs:v1 --name dojo
```

Verify the node has it (before you apply the Deployment, not after):

```bash
docker exec dojo-control-plane crictl images | grep dojo-nextjs
```

If this is empty, the deployment will `ErrImagePull` forever. `imagePullPolicy: IfNotPresent` tells the kubelet to use the local store without trying the registry — if the image isn't there, the pod fails immediately with a clear error instead of a confusing timeout.

## 4. Deploy to dojo-nextjs

```bash
kubectl create namespace dojo-nextjs --dry-run=client -o yaml | kubectl apply -f -
```

```yaml
# deploy.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nextjs
  namespace: dojo-nextjs
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nextjs
  template:
    metadata:
      labels:
        app: nextjs
    spec:
      containers:
        - name: nextjs
          image: dojo-nextjs:v1
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 3000
          readinessProbe:
            httpGet:
              path: /api/health
              port: 3000
            initialDelaySeconds: 5
            periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: nextjs
  namespace: dojo-nextjs
spec:
  selector:
    app: nextjs
  ports:
    - port: 80
      targetPort: 3000
```

```bash
kubectl apply -f deploy.yaml
kubectl -n dojo-nextjs rollout status deployment/nextjs
```

## Why a readiness probe on `/api/health`

Kubernetes marks a pod `Ready` only when the readiness probe passes. Without one:

- Traffic is sent to the pod the instant the container starts, before Next.js has finished booting (~1–2 s). You get connection refused errors during rolling deploys.
- During a `RollingUpdate`, Kubernetes terminates the old pod as soon as the new one is `Running` — but `Running` means the process started, not that it's serving. A readiness probe delays the old-pod termination until the new pod actually responds.

The `/api/health` route in this app returns `{ status: "ok" }` with a 200 — that is all a readiness probe needs.

## Debugging tips

**Pod stuck in `ErrImagePull`:**
```bash
kubectl -n dojo-nextjs describe pod -l app=nextjs | grep -A5 Events
# Most likely: kind load was not run, or the image name/tag doesn't match
```

**Pod `CrashLoopBackOff`:**
```bash
kubectl -n dojo-nextjs logs -l app=nextjs --previous
# Next.js standalone fails if HOSTNAME is not set — the ENV in the Dockerfile covers this
```

**Readiness probe failing:**
```bash
# Shell into the pod and hit the health route directly
kubectl -n dojo-nextjs exec -it deploy/nextjs -- wget -qO- http://localhost:3000/api/health
```
