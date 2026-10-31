# Solution — Lock the Namespace

Two moves: **enforce** the standard on the namespace, and **refactor** the workload so a compliant pod is admitted. Do them in that order's mirror image in production (warn → enforce), but here either order reaches the same end state.

## Step 1 — enforce restricted on the namespace

```bash
kubectl label ns dojo-psa \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/audit=restricted \
  --overwrite
```

`enforce-version=latest` pins the policy to the newest standard the API server ships; pin it to a specific minor (`v1.31`) in production so a cluster upgrade can't silently tighten the gate under your running workloads.

The moment this lands, the **old** privileged pod keeps running (enforce is create/update-time only), but any new pod that violates restricted is rejected. Confirm the gate is live by trying to recreate the bad pod:

```bash
kubectl -n dojo-psa rollout restart deploy/api
kubectl -n dojo-psa rollout status deploy/api --timeout=15s   # will FAIL — new pods rejected
kubectl -n dojo-psa get events --sort-by=.lastTimestamp | grep -i forbidden
# ... violates PodSecurity "restricted:latest": privileged (...), allowPrivilegeEscalation != false,
#     unrestricted capabilities, runAsNonRoot != true, seccompProfile ...
```

That `FailedCreate` event, listing every violation at once, is PSA's best feature — it tells you exactly what to fix.

## Step 2 — refactor the workload to comply

The planted container uses `nginx:1.27-alpine`, whose master process **must** run as root to bind port 80. You can't satisfy `runAsNonRoot` with it — swap to the unprivileged variant, which runs as uid 101 and binds 8080:

```yaml
# api.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
  namespace: dojo-psa
  labels:
    app: api
spec:
  replicas: 1
  selector:
    matchLabels:
      app: api
  template:
    metadata:
      labels:
        app: api
    spec:
      securityContext:
        runAsNonRoot: true             # pod-level: inherited by every container
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: api
          image: nginxinc/nginx-unprivileged:1.27-alpine   # uid 101, binds 8080
          ports:
            - containerPort: 8080
          securityContext:
            runAsNonRoot: true          # also set at container level (belt + braces)
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
            seccompProfile:
              type: RuntimeDefault
```

```bash
kubectl apply -f api.yaml
kubectl -n dojo-psa rollout status deploy/api
bash courses/course-01-ops-security/challenges/15-pod-security-admission/verify.sh
```

## Why each field matters

- **`runAsNonRoot: true`** is a runtime gate: the kubelet refuses to start the container if its effective UID resolves to 0. It's the single most valuable line — a root process that breaks out of the container (see challenge 18) is root on the node.
- **`allowPrivilegeEscalation: false`** sets `no_new_privs` on the process, so a `setuid` binary inside the container can't hand back the privileges you dropped.
- **`drop: ["ALL"]`** starts the container with zero Linux capabilities. nginx-unprivileged needs none because it binds a high port. A workload that needs port 80 would add back only `NET_BIND_SERVICE` — and that alone pushes it out of `restricted` into `baseline`.
- **`seccompProfile: RuntimeDefault`** applies the container runtime's default syscall filter. Without it, `restricted` rejects the pod outright; its absence is the most commonly forgotten field.

## Debugging restricted-mode rejections

| Symptom | Likely cause | Fix / diagnose |
|---------|--------------|----------------|
| `deploy` shows 0/1, no pods at all | ReplicaSet create blocked by PSA | `kubectl -n dojo-psa describe rs -l app=api` → read the `FailedCreate` message; it lists every violated field |
| `violates ... runAsNonRoot != true` | image runs as root, or field unset | swap to an unprivileged image **and** set `runAsNonRoot: true` |
| `violates ... seccompProfile` | no seccomp profile set | add `seccompProfile.type: RuntimeDefault` at pod or container level |
| Pod admitted but `CrashLoopBackOff` with `bind() permission denied` | kept port 80 under non-root | use the unprivileged image on 8080, or add `NET_BIND_SERVICE` (which breaks restricted) |
| Labels set but old privileged pod still running | enforce is create-time only | `kubectl -n dojo-psa rollout restart deploy/api` to force recreation through the gate |
| `warn`/`audit` fire but nothing is blocked | only `enforce` rejects; warn/audit are advisory | that's by design — set all three, enforce is the teeth |

Diagnose the exact violations without changing anything by dry-running against the API server:

```bash
kubectl label --dry-run=server -o yaml ns dojo-psa \
  pod-security.kubernetes.io/enforce=restricted
# the server replies with warnings for every pod already running that WOULD be rejected
```

> **War story.** A platform team flipped `enforce=restricted` across every namespace in one `kubectl label` loop on a Friday, confident because CI had been green for weeks. It had — CI only ran `baseline`. Thirty services with Fluent Bit sidecars mounting `hostPath` for `/var/log` were already running, so nothing fell over immediately (enforce doesn't evict). Then the weekend's node autoscaler recycled nodes, every rescheduled sidecar hit the gate, and log shipping silently died namespace by namespace. The incident wasn't the label — it was skipping `warn=restricted` first, which would have printed the exact violations into every engineer's terminal days earlier. Rollout order is the lesson: **warn → audit → read the events → enforce.**

## Hardening preview

- Set a **cluster default** via the `PodSecurity` admission config (`AdmissionConfiguration` file passed to the API server) so brand-new namespaces start at `enforce=baseline, warn=restricted` instead of wide open.
- PSA is coarse (3 fixed standards). For per-field policy — "no image from an untrusted registry", "every pod must set a `priorityClassName`" — layer a policy engine (Kyverno, OPA Gatekeeper, or Validating Admission Policy / CEL) on top. PSA is the floor, not the ceiling.
