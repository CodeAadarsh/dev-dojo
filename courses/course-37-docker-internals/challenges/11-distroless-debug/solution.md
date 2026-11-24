# Solution: Distroless Debug

## Step 1: Confirm the crash

```bash
kubectl get pods -n dojo-docker-distroless
# NAME                   READY   STATUS             RESTARTS   AGE
# api-5d9c8f7b9-xk2p4    0/1     CrashLoopBackOff   4          3m

kubectl logs -n dojo-docker-distroless deploy/api
# ERROR: Cannot connect to database at postgresql://wrong-host:5432/db
```

## Step 2: Try exec — it fails

```bash
kubectl exec -n dojo-docker-distroless deploy/api -- sh
# OCI runtime exec failed: exec: "sh": not found
```

This is the distroless wall. No shell, no tools.

## Step 3: Inject an ephemeral debug container

```bash
# Get the pod name first
POD=$(kubectl get pod -n dojo-docker-distroless -l app=api -o jsonpath='{.items[0].metadata.name}')

# Attach a busybox debug container that shares namespaces with the api container
kubectl debug -it -n dojo-docker-distroless "$POD" \
  --image=busybox:1.36 \
  --target=api
```

You are now inside a busybox container that shares the **PID namespace** with `api`. This means you can see the api process's environment:

```bash
# Inside the ephemeral container:
env | grep DATABASE
# DATABASE_URL=postgresql://wrong-host:5432/db

# You can also see the api process
ps aux
# PID 1: sh -c echo "Starting api..." ...
```

The bug is clear: `DATABASE_URL` points to `wrong-host`.

## Step 4: Fix the ConfigMap

```bash
kubectl patch configmap app-config -n dojo-docker-distroless \
  -p '{"data":{"DATABASE_URL":"postgresql://correct-host:5432/db"}}'
```

## Step 5: Restart to pick up the new config

ConfigMap changes do not automatically propagate to existing pods. A rollout restart is needed:

```bash
kubectl rollout restart deployment api -n dojo-docker-distroless
kubectl rollout status deployment api -n dojo-docker-distroless
```

## How kubectl debug works

`kubectl debug` uses the **ephemeral containers** API (stable since Kubernetes 1.25). It patches the Pod spec to add a temporary container that:

- Shares the **PID namespace** with the target container (`--target=api`)
- Shares the **network namespace** (can reach the same endpoints)
- Has its **own filesystem** (but can access the target's filesystem via `/proc/<pid>/root`)
- Is **not** restarted if it exits — truly ephemeral

The key insight: the ephemeral container sees all the same environment variables, open file descriptors, and network connections as the production container. It is as close as you can get to being "inside" a distroless container without putting a shell in the image.

## The production pattern

For distroless containers in production, establish this debugging runbook:

```bash
# Standard debug attach
kubectl debug -it -n <namespace> <pod> \
  --image=busybox:1.36 \
  --target=<container-name>

# If you need networking tools
kubectl debug -it -n <namespace> <pod> \
  --image=nicolaka/netshoot:latest \
  --target=<container-name>

# Access the target's filesystem
ls /proc/1/root/   # the target container's rootfs
```

Never add a shell back to a distroless image to make debugging easier. That's how you undo all the security hardening.
