# Solution — Harden the Pod, CKS-Style

Apply the full hardened Deployment:

```yaml
# secure-app.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: secure-app
  namespace: dojo-cks
  labels: { app: secure-app }
spec:
  replicas: 1
  selector:
    matchLabels: { app: secure-app }
  template:
    metadata:
      labels: { app: secure-app }
    spec:
      securityContext:                 # pod-level
        runAsNonRoot: true
        runAsUser: 1000
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: app
          image: busybox:1.36
          command: ["sh", "-c", "sleep 3600"]
          securityContext:             # container-level
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
```

```bash
kubectl apply -f secure-app.yaml
kubectl -n dojo-cks rollout status deploy/secure-app
bash courses/course-04-cert-cka-ckad-cks/challenges/06-cks-harden-pod/verify.sh
```

## Pod-level vs container-level (the gotcha)

| Field | Where it lives |
|-------|----------------|
| `runAsNonRoot`, `runAsUser`, `fsGroup`, `seccompProfile` | pod **or** container |
| `readOnlyRootFilesystem`, `allowPrivilegeEscalation`, `capabilities` | **container only** |

Put a container-only field at pod level and it's silently ignored — a classic reason a "hardened" pod still fails PSA `restricted`.

## When read-only rootfs breaks the app

`busybox sleep` writes nothing, so `readOnlyRootFilesystem: true` is free here. Real apps often need a writable path (nginx wants `/var/cache/nginx` and `/var/run`). The secure fix is **not** to drop the flag — it's to mount writable `emptyDir`s only where needed:

```yaml
      volumes:
        - name: tmp
          emptyDir: {}
      containers:
        - name: app
          volumeMounts:
            - { name: tmp, mountPath: /tmp }
```

That keeps the root filesystem immutable while giving the process the scratch space it needs — secure *and* running, which is exactly what CKS grades.

## Why each control matters

- **runAsNonRoot / runAsUser:** a container running as root that escapes is root on the node. Non-root shrinks the blast radius.
- **allowPrivilegeEscalation: false:** blocks `setuid`/`setcap` tricks that regain privileges.
- **readOnlyRootFilesystem:** an attacker can't drop a binary or modify the app in place.
- **drop ALL capabilities:** start from zero Linux capabilities; add back only the one or two an app truly needs.
- **seccompProfile RuntimeDefault:** restricts the syscalls the container may make to the runtime's curated set, shrinking the kernel attack surface.
