# Solution — Ship It: Gunicorn + Docker + k8s

Four steps: build, load, namespace, manifest.

## Step 1 — Build the image

```bash
cd $HOME/.kube-dojo-work/06-dockerize-and-deploy
docker build -t flask-app:dojo .
```

The `Dockerfile` in your work directory uses `python:3.12-slim`, installs Flask + Gunicorn, and sets the CMD to run two workers. Nothing to change unless you want to experiment.

## Step 2 — Load into kind

```bash
kind load docker-image flask-app:dojo --name dojo
```

kind clusters run inside Docker containers. The kubelet inside the kind node can't see your local Docker daemon's image store — it has its own containerd. `kind load docker-image` exports the image from Docker and imports it into the node's containerd. Without this step the pod stays in `ErrImageNeverPull` (because `imagePullPolicy: Never` tells it not to try a registry, and the image isn't there).

## Step 3 — Create the namespace

```bash
kubectl create namespace dojo-flask --dry-run=client -o yaml | kubectl apply -f -
```

The `--dry-run | apply` pattern is idempotent: it creates the namespace if missing, no-ops if it already exists.

## Step 4 — Apply the manifest

```yaml
# deploy.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: flask-app
  namespace: dojo-flask
spec:
  replicas: 1
  selector:
    matchLabels:
      app: flask-app
  template:
    metadata:
      labels:
        app: flask-app
    spec:
      containers:
        - name: flask-app
          image: flask-app:dojo
          imagePullPolicy: Never
          ports:
            - containerPort: 8000
          command:
            - gunicorn
            - -w
            - "2"
            - -b
            - 0.0.0.0:8000
            - "app:create_app()"
          readinessProbe:
            httpGet:
              path: /health
              port: 8000
            initialDelaySeconds: 5
            periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: flask-app
  namespace: dojo-flask
spec:
  selector:
    app: flask-app
  ports:
    - port: 80
      targetPort: 8000
```

```bash
kubectl apply -f deploy.yaml
kubectl rollout status deployment/flask-app -n dojo-flask
```

## Why each field matters

**`imagePullPolicy: Never`.** Without it the default is `IfNotPresent`, which will try a registry pull if the image is not cached — and a local `flask-app:dojo` tag won't resolve in any registry. `Never` tells the kubelet: if it's not already in containerd, fail immediately. This forces you to complete the `kind load` step first.

**`command` override.** The Dockerfile CMD already sets Gunicorn, but overriding it in the Deployment spec makes the intent explicit in the cluster manifest — the source of truth shifts from "buried in a Dockerfile" to "visible in the YAML you apply". In production you'd almost always override CMD here.

**`readinessProbe` with `initialDelaySeconds: 5`.** Gunicorn forks workers before binding, so the port isn't open for a brief window after container start. Without `initialDelaySeconds` the first probe fires too soon and may fail, cycling the pod before it's actually broken. 5s is conservative for a trivial app; for apps with DB migrations at startup you'd set this to match the worst-case warm-up time.

**Service `port: 80 → targetPort: 8000`.** Callers inside the cluster hit port 80 (the conventional HTTP port); the kube-proxy translates to port 8000 on the pod. This means you can change the app's listen port without updating every consumer of the Service.

## Attacker's view

A `ClusterIP` service is only reachable from inside the cluster. If this were `NodePort` or `LoadBalancer`, the `/health` endpoint (and anything else the app exposes) would be reachable from outside the cluster without authentication. `ClusterIP` is the right default; add an `Ingress` with TLS termination if external access is needed.
