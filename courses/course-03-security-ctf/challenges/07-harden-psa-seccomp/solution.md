# Solution — Restricted By Default

Two moves, in either order: enable enforcement on the namespace, and ship a compliant workload. Doing the label first is instructive — you'll watch the non-compliant rollout get rejected.

## Step 1 — enforce `restricted` on the namespace

```bash
kubectl label namespace dojo-hardpsa \
  pod-security.kubernetes.io/enforce=restricted --overwrite
```

Good practice is to add `warn` and `audit` at the same level, so violators are surfaced in `kubectl` warnings and the audit log, not just blocked:

```bash
kubectl label namespace dojo-hardpsa \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/audit=restricted --overwrite
```

Right now the already-running root pod keeps running — PSA never evicts. But if you force the existing Deployment to roll (`kubectl -n dojo-hardpsa rollout restart deploy/legacy-app`) *before* fixing its template, the new pod is rejected and the Deployment stalls:

```bash
kubectl -n dojo-hardpsa get events --sort-by=.lastTimestamp | grep -i forbidden
# ... FailedCreate ... violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false, ...
```

That rejection *is* the control doing its job.

## Step 2 — a compliant workload

Rebuild `legacy-app` so a pod clears the `restricted` bar:

```yaml
# legacy-app.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: legacy-app
  namespace: dojo-hardpsa
  labels:
    app: legacy-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: legacy-app
  template:
    metadata:
      labels:
        app: legacy-app
    spec:
      securityContext:
        runAsNonRoot: true          # required by restricted
        runAsUser: 1000             # non-zero, so the kubelet can verify non-root
        seccompProfile:
          type: RuntimeDefault      # required by restricted
      containers:
        - name: app
          image: busybox:1.36
          command: ["sh", "-c", "sleep 3600"]
          securityContext:
            allowPrivilegeEscalation: false   # required by restricted
            capabilities:
              drop: ["ALL"]                   # required by restricted
```

Apply and verify:

```bash
kubectl apply -f legacy-app.yaml
kubectl -n dojo-hardpsa rollout status deploy/legacy-app
bash courses/course-03-security-ctf/challenges/07-harden-psa-seccomp/verify.sh
```

## Why each field is required by `restricted`

| Field | What it stops |
|-------|---------------|
| `runAsNonRoot: true` + non-zero `runAsUser` | A root process in the container is root on the shared host kernel if it escapes. Non-root shrinks what a breakout can touch. |
| `allowPrivilegeEscalation: false` | Blocks `setuid`/`setcap` binaries and `no_new_privs=0` from gaining more than the process started with — kills a whole class of in-container privilege gains. |
| `capabilities.drop: ["ALL"]` | Removes `CAP_SYS_ADMIN`, `CAP_NET_RAW`, `CAP_SYS_PTRACE`, etc. — the capabilities most escape and sniffing techniques depend on. Add back only the one or two a workload truly needs. |
| `seccompProfile.type: RuntimeDefault` | Applies the container runtime's default seccomp filter, blocking ~44 dangerous syscalls (`keyctl`, `ptrace`, `mount`, …). `Unconfined` (the pod default) allows all syscalls. |

`restricted` bundles all four plus host-namespace/hostPath/privileged bans. It is the profile that removes the exact ingredients the Course 03 escape relied on.

## Debugging a stuck rollout

> **War story.** Rolling PSA `restricted` across a shared cluster at work, I flipped a namespace to `enforce=restricted` on a Friday and a team's Deployment went to zero available replicas over the weekend. No crash, no `CrashLoopBackOff` — the ReplicaSet simply couldn't create pods, and the old pods had already been drained by an unrelated node cycle. The signal was buried: `kubectl get deploy` showed `0/3`, and the real message was only on the **ReplicaSet** events, not the Deployment or any pod (there were no pods). The lesson: when a Deployment is stuck at zero under PSA, don't `describe` the Deployment — `describe` the ReplicaSet or grep events for `violates PodSecurity`. And always roll out `warn`+`audit` *first* in a soak window so you see every violator before `enforce` can hurt anyone.

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Deployment stuck at `0/N`, no pods exist | PSA rejected pod creation; message is on the ReplicaSet, not the pod | `kubectl -n dojo-hardpsa describe rs -l app=legacy-app` or `kubectl get events | grep -i 'violates PodSecurity'` |
| Pod stays `CreateContainerConfigError` / won't start | `runAsNonRoot: true` with no (or zero) `runAsUser` on a root image | Set `runAsUser: 1000`; message: `container has runAsNonRoot and image will run as root` |
| Verifier still says not compliant though label is set | You labelled the namespace but the *old* root pod is the only one Running | Roll the Deployment so a compliant pod replaces it; PSA never mutates existing pods |
| `enforce=restricted` label silently ignored | Typo in the key (it is `pod-security.kubernetes.io/enforce`) or value not one of privileged/baseline/restricted | `kubectl get ns dojo-hardpsa --show-labels` and fix the key/value |

## Beyond the namespace label

- Set a **cluster-wide default** with the `PodSecurity` admission configuration (`AdmissionConfiguration` on the API server) so new namespaces are `restricted` unless explicitly opted down — true "restricted by default."
- PSA is coarse (three profiles). For finer rules (require a specific user range, forbid a particular image registry) layer a policy engine — **Kyverno** or **OPA/Gatekeeper** — on top.
- Pin the profile to a Kubernetes version (`enforce-version`) so a cluster upgrade can't silently change what `restricted` means under you.
