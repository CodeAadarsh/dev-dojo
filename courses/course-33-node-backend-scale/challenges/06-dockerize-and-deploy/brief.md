# Dockerize and Deploy to Kubernetes

The platform team hands you a Node/TypeScript API and asks: *"Can you get this running in the cluster before the Friday demo? It needs to be in a slim, non-root image with a readiness probe so traffic doesn't hit it until it's actually ready."*

This is the BRIDGE challenge: you cross from local code to a live pod in the dojo kind cluster.

## Context

`setup.sh` plants a working Node/TS API project in your work directory:

```
~/.kube-dojo-work/06-dockerize-and-deploy/
├── package.json          # TypeScript + ts-node deps, pinned versions
├── tsconfig.json         # target ES2022, outDir ./dist
├── src/
│   └── index.ts          # Express API with GET /health and GET /items
└── Dockerfile            # multi-stage skeleton — fill in the blanks
```

The API listens on `PORT` (default 3000) and responds:
- `GET /health` → `200 {"status":"ok"}`
- `GET /items`  → `200 [...]`

The `Dockerfile` is a skeleton — you must complete it.

## Prerequisites

- Docker Desktop running
- kind cluster `dojo` running (`kubectl config current-context` → `kind-dojo`)

## Mission

### Step 1 — Complete the Dockerfile

The skeleton has `# TODO` markers in three places:

1. **Build stage:** install deps and compile TypeScript to `./dist`.
2. **Runtime stage:** copy only the compiled output and production `node_modules` from the build stage — no source, no dev deps.
3. **Non-root user:** the runtime container must run as a non-root user.

The final image must be based on `node:20-alpine` and the process must run as a non-root user.

### Step 2 — Build and load

```bash
cd ~/.kube-dojo-work/06-dockerize-and-deploy
docker build -t dojo-node-api:1.0.0 .
kind load docker-image dojo-node-api:1.0.0 --name dojo
```

### Step 3 — Deploy to Kubernetes

Create a `Deployment` and a `Service` in namespace `dojo-node` that satisfy all of the verifier's checks:

```bash
kubectl create namespace dojo-node --dry-run=client -o yaml | kubectl apply -f -
```

The `Deployment` must:
- Use image `dojo-node-api:1.0.0` with `imagePullPolicy: IfNotPresent`
- Have at least 1 ready replica
- Include a `readinessProbe` on HTTP path `/health` port `3000`
- Run the container as a non-root user (`securityContext.runAsNonRoot: true`)

The `Service` must:
- Expose port 80 → targetPort 3000
- Select the pods from the Deployment

### What `verify.sh` checks

| Check | Why it matters |
|-------|----------------|
| Namespace `dojo-node` exists | Isolation — all lab state is under `dojo-*` |
| Deployment `dojo-node-api` exists in `dojo-node` | Deployment present |
| `readyReplicas >= 1` | Pod is healthy and passed the readiness probe |
| A `readinessProbe` is configured on the deployment | Traffic only reaches a ready pod |
| Pod runs as non-root (`runAsNonRoot: true` OR numeric UID != 0) | Security baseline |
| The running image is `dojo-node-api:1.0.0` | You loaded and used the correct image |

## Debugging dockerize-and-deploy

**Symptom:** Pod stuck `ErrImagePull` or `ImagePullBackOff`.  
**Cause:** The image was never loaded into the kind node cache. `imagePullPolicy: Always` forces a pull from a registry, which fails for a local image.  
**Fix:** `kind load docker-image dojo-node-api:1.0.0 --name dojo` + set `imagePullPolicy: IfNotPresent` in the Deployment.

**Symptom:** Pod starts but never becomes `Ready`; `describe` shows readiness probe failing.  
**Cause:** The `/health` endpoint is not reachable on port 3000 from inside the pod, or the app crashes on startup.  
**Fix:** `kubectl logs -n dojo-node <pod>` to see app stderr. Check that `PORT` env var is set to `3000` (or that the default matches). Verify the probe path and port match exactly.

**Symptom:** Pod `CrashLoopBackOff` with permission denied on a file.  
**Cause:** The non-root user in the runtime stage doesn't have read access to the compiled files.  
**Fix:** In the Dockerfile, after copying files into the runtime stage, `RUN chown -R node:node /app` before the `USER node` instruction.

**Symptom:** TypeScript compile error during `docker build`.  
**Cause:** `devDependencies` (TypeScript, ts-node) are not installed in the build stage, or `npx tsc` is run before `npm install`.  
**Fix:** In the build stage, run `npm ci` (which installs all deps including dev), then `npx tsc`.

> **War story.** At SAP we deployed a Node service to Cloud Foundry as root inside the container, then spent a sprint "hardening" it when the security scan flagged it. The fix — adding `USER node` to the Dockerfile — took 5 minutes. The audit finding, the sprint planning, the review: 2 weeks. Non-root is a one-line change you make at build time or a compliance incident you fix under pressure.

## Verify

```bash
bash courses/course-33-node-backend-scale/challenges/06-dockerize-and-deploy/verify.sh
```

All checks pass → flag printed.
