# Solution: Security Lockdown

## Why the default is insecure

By default, a container runs as whatever UID the image defines — nginx defaults to root (UID 0). Docker grants the container most Linux capabilities. The OverlayFS upperdir is writable. `setuid` binaries can still escalate. All of this makes the blast radius of a compromised app much larger than it needs to be.

The four hardening fields are the first line of defense.

## The gotcha: nginx + read-only filesystem

Before we fix anything, there is a trap. `nginx:1.27-alpine` writes to two paths at startup:

- `/var/cache/nginx` — temporary cache files
- `/var/run/nginx.pid` — the master process PID file

With `readOnlyRootFilesystem: true`, nginx will `open()` those paths and get `EROFS`. It will crash immediately. The fix is to give it writable `emptyDir` volumes at exactly those two paths — everything else can stay read-only.

Additionally, `runAsNonRoot: true` requires the image to actually start as a non-root user. `nginx:1.27-alpine` has the `nginx` user at **UID 101** — set `runAsUser: 101` to tell Kubernetes which UID to use.

## Full patched Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app
  namespace: dojo-docker-security
  annotations:
    dojo.docker/security-level: "hardened"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: app
  template:
    metadata:
      labels:
        app: app
    spec:
      securityContext:
        runAsNonRoot: true        # pod-level: reject if container would run as root
        runAsUser: 101            # nginx user in nginx:1.27-alpine
      volumes:
      - name: nginx-cache
        emptyDir: {}
      - name: nginx-run
        emptyDir: {}
      containers:
      - name: app
        image: nginx:1.27-alpine
        ports:
        - containerPort: 80
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop:
            - ALL
        volumeMounts:
        - name: nginx-cache
          mountPath: /var/cache/nginx
        - name: nginx-run
          mountPath: /var/run
```

Apply:

```bash
kubectl apply -f app-hardened.yaml
kubectl rollout status deployment app -n dojo-docker-security
```

Verify it's actually running as non-root:

```bash
kubectl exec -n dojo-docker-security deploy/app -- id
# uid=101(nginx) gid=101(nginx)
```

Verify read-only filesystem:

```bash
kubectl exec -n dojo-docker-security deploy/app -- touch /test 2>&1
# touch: /test: Read-only file system
```

## What each field does under the hood

| Field | Kernel mechanism |
|---|---|
| `runAsNonRoot: true` | Kubelet rejects the pod if `runAsUser` resolves to 0 |
| `runAsUser: 101` | Sets `uid` in the OCI runtime spec → `runc` calls `setuid(101)` before exec |
| `allowPrivilegeEscalation: false` | Sets `no_new_privs` bit via `prctl(PR_SET_NO_NEW_PRIVS, 1)` — `setuid` binaries can't gain root |
| `readOnlyRootFilesystem: true` | Mounts the OverlayFS upperdir read-only in the OCI spec |
| `capabilities.drop: [ALL]` | Calls `cap_set_proc()` to clear the entire capability bounding set |

Together these four fields shrink the blast radius of a compromised container from "effective root on the node" to "unprivileged process with no filesystem write and no special kernel powers."
