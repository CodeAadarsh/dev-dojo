# Deploy API to kind

*"Works on my machine"* is not a deployment. Your team has been iterating on a local Flask API. Now it's time to ship it: build a container image, load it into the kind cluster, write a Deployment + Service, and prove it serves traffic.

This challenge mirrors the daily SRE workflow: every production deploy starts with someone building an image and writing Kubernetes manifests. Understanding why each step is necessary — especially the `kind load` step that trips up everyone the first time — is what separates a developer who can code from one who can actually ship.

## Mission

The setup script writes a small Flask API and a Dockerfile into your work directory. Your job:

1. Inspect `app.py` and `Dockerfile` in `$HOME/.kube-dojo-work/06-deploy-api-to-kind/`.
2. Edit `deploy.yaml`: replace `FILL_IN` with the correct image tag (`dojo-api:v1`).
3. Create namespace `dojo-backend` and apply the manifest:
   ```bash
   kubectl apply -f deploy.yaml
   ```
4. Run the verifier — it builds the image, loads it, and checks your deployment.

## Setup

```bash
bash courses/course-10-backend-engineering/challenges/06-deploy-api-to-kind/setup.sh
```

**Prereqs:** Docker Desktop running + a kind cluster named `dojo` (`kind create cluster --name dojo`).

## What the verifier checks

The verifier will accept your work only when **all of these are true**:

1. `docker build -t dojo-api:v1 .` succeeds from the work directory.
2. `kind load docker-image dojo-api:v1 --name dojo` succeeds.
3. A **Deployment** exists in namespace `dojo-backend` whose container image contains `dojo-api`.
4. `readyReplicas >= 1` — at least one pod is running and passing its readiness check.
5. A pod labeled `app=dojo-api` exists in `dojo-backend`.
6. `GET /healthz` via port-forward returns **HTTP 200**.

## The `kind load` step — read this

kind clusters maintain their own image store inside the cluster's Docker containers. Images you build on your Mac are **not** visible inside the cluster automatically. `kind load docker-image <tag> --name dojo` copies the image from your host Docker daemon into every kind node's containerd store.

Without this step, kubelet will see `imagePullPolicy: IfNotPresent`, find no local copy (because it is looking *inside the node container*, not on your Mac), and attempt a registry pull. Since `dojo-api:v1` does not exist on Docker Hub, the pod will stay in `ImagePullBackOff` forever.

Run the verifier:

```bash
bash courses/course-10-backend-engineering/challenges/06-deploy-api-to-kind/verify.sh
```
