# Restricted By Default

The container-escape challenge earlier in this course worked because the target pod was a gift: it ran as **root**, kept **every Linux capability**, allowed **privilege escalation**, and ran with **no seccomp filter**. That is the default posture of a pod with no `securityContext` — and it is the single biggest multiplier on a container breakout. Strip those four things away and most escape primitives simply aren't there.

Namespace `dojo-hardpsa` ships a `legacy-app` Deployment with exactly that over-permissive shape. Your job is to make the namespace reject pods like it, and to rebuild the workload so it survives the stricter bar.

## What's running now

The setup script planted a Deployment `legacy-app` in `dojo-hardpsa`:

```
runAsUser: 0                 # root
allowPrivilegeEscalation: true (default, not set)
capabilities: all default caps retained
seccompProfile: none (Unconfined)
```

The namespace has **no** Pod Security labels, so the API server admits this without complaint. Both facts are the problem.

## Mission — target state

Two moves:

1. **Turn on enforcement.** Label the namespace with the Pod Security Admission *enforce* mode set to `restricted`:
   `pod-security.kubernetes.io/enforce=restricted`.
2. **Make the workload compliant.** Rebuild `legacy-app` (or ship a replacement workload) so a pod actually runs under the `restricted` bar. Compliant means, at minimum:
   - `runAsNonRoot: true` (and a non-zero `runAsUser`, so the kubelet can verify it),
   - `allowPrivilegeEscalation: false`,
   - `capabilities.drop: ["ALL"]`,
   - `seccompProfile.type: RuntimeDefault`.

The verifier accepts your work when **both** of these are true:

1. Namespace `dojo-hardpsa` carries the label `pod-security.kubernetes.io/enforce=restricted`.
2. At least one pod in the namespace is **Running** and compliant: `allowPrivilegeEscalation=false`, `capabilities.drop` includes `ALL`, `runAsNonRoot=true`, and `seccompProfile.type=RuntimeDefault` (either at pod or container level).

Run the verifier (step 2 above) once both hold; it prints the flag.

## Two gotchas that will bite you

> **PSA only gates admission — it does not mutate or evict.** Labelling the namespace `enforce=restricted` does **nothing** to the already-running non-compliant pod; existing pods keep running. Enforcement only fires when a *new* pod is created. So after you label the namespace, the old root pod is still there until its Deployment rolls a new (compliant) ReplicaSet. If your updated template is still non-compliant, the ReplicaSet's pod creation is **rejected** and you'll see the Deployment stall with zero new pods and a `FailedCreate` event — that is PSA working, not a bug.

> **`runAsNonRoot: true` alone won't start the pod.** With an image whose default user is root (like `busybox`), setting `runAsNonRoot: true` without a non-zero `runAsUser` makes the kubelet refuse to start the container: `container has runAsNonRoot and image will run as root`. You must also set `runAsUser` to something non-zero (e.g. `1000`).

## Why `restricted`, specifically

Pod Security Admission ships three built-in profiles: `privileged` (no restrictions), `baseline` (blocks the obviously dangerous — host namespaces, privileged, hostPath), and `restricted` (the hardened bar: non-root, no cap adds + drop-ALL, seccomp RuntimeDefault, no privilege escalation, seccomp/runtime defaults). `restricted` is the profile that removes the ingredients a container escape needs. Setting it as the namespace default — *restricted by default* — means a future careless manifest can't quietly reintroduce the root-with-all-caps pod you just eliminated. Defense that holds only until the next `kubectl apply` isn't defense; PSA makes the floor sticky.
