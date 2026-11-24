# Solution: Volume Leakage

## Root cause

The `counter` Deployment has no Volume. The command writes to `/data/count.txt`, but that path lives inside the **container's writable overlay layer** — the ephemeral copy-on-write layer that is recreated fresh from the image on every container restart. No persistence means every restart starts at 0.

## The fix

Patch the Deployment to add an `emptyDir` volume mounted at `/data`.

```yaml
# Full patched Deployment
apiVersion: apps/v1
kind: Deployment
metadata:
  name: counter
  namespace: dojo-docker-volume
spec:
  replicas: 1
  selector:
    matchLabels:
      app: counter
  template:
    metadata:
      labels:
        app: counter
    spec:
      volumes:
      - name: data-vol
        emptyDir: {}
      containers:
      - name: counter
        image: busybox:1.36
        command:
        - sh
        - -c
        - |
          COUNT=$(cat /data/count.txt 2>/dev/null || echo 0)
          COUNT=$((COUNT + 1))
          echo $COUNT > /data/count.txt
          echo "Count: $COUNT"
          sleep 30
        volumeMounts:
        - name: data-vol
          mountPath: /data
```

Apply it:

```bash
kubectl apply -f counter-fixed.yaml
kubectl rollout restart deployment counter -n dojo-docker-volume
kubectl rollout status deployment counter -n dojo-docker-volume
```

## emptyDir vs PVC — when to use each

| Volume type | Survives container restart? | Survives pod deletion? | Use when |
|---|---|---|---|
| `emptyDir` | Yes | No | Scratch space, caches, inter-container sharing within a pod |
| PersistentVolumeClaim | Yes | Yes | Actual data you can't afford to lose |

**emptyDir** is backed by the node's filesystem (or RAM if `medium: Memory`). It lives as long as the pod exists on that node. A container crash inside the pod? The emptyDir survives. The pod gets rescheduled to a different node? The emptyDir is gone.

For true persistence across pod deletions and node failures, use a PVC:

```yaml
# PVC approach (requires a StorageClass)
volumes:
- name: data-vol
  persistentVolumeClaim:
    claimName: counter-pvc
```

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: counter-pvc
  namespace: dojo-docker-volume
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 100Mi
```

## Why the container layer is not for data

The container writable layer works via **OverlayFS copy-on-write**: on first write, the kernel copies the file from the read-only image layer into the container's private upperdir. The data is physically on the node's disk, but it is owned by that specific container instance. When the container is destroyed and recreated (on restart), a fresh upperdir is created — your writes are gone.

A Volume bypasses OverlayFS entirely: the directory is bind-mounted into the container from outside the overlay stack, so writes go directly to the volume's backing storage.
