# Defense in Depth: Hardening Checklist

> **Module 07 · Course 03** — Every challenge in this course exploited exactly one missing control: an automounted token, an over-broad Role, a flat network with no policy. This module stops looking at single controls and assembles them into a *stack*. Defense in depth means no single misconfiguration is catastrophic, because the next layer catches the climb. You'll walk each layer of the stack with the concrete Kubernetes primitive that implements it, then collapse it all into one consolidated hardening checklist you can run against a real cluster — and finish on the skill that separates people who *talk* about hardening from people who *ship* it: debugging a hardened pod that won't start, without re-opening the hole you just closed.

You already shipped workloads to production. The gap this module closes is going from "I know what `securityContext` is" to "I can state, for a given pod, exactly which control stops which step of the escalation chain, and I can tighten all of them at once without breaking the workload."

---

## The 4 C's, recapped as a control stack

Module 01 introduced the nested 4 C's. Here they are again, but now each layer is annotated with the *shippable primitive* you harden it with — this table is the spine of the whole checklist below.

```
┌──────────────────────── Cloud ────────────────────────┐
│  IAM least-privilege · metadata egress blocked         │
│  ┌──────────────────── Cluster ──────────────────┐     │
│  │  RBAC · NetworkPolicy · Admission · Audit log  │     │
│  │  ┌──────────────── Container ────────────┐     │     │
│  │  │  PSA restricted · seccomp · AppArmor   │     │     │
│  │  │  non-root · RO rootfs · drop caps      │     │     │
│  │  │  ┌──────────── Code ────────────┐      │     │     │
│  │  │  │  scanned deps · signed image  │      │     │     │
│  │  │  └───────────────────────────────┘     │     │     │
│  │  └────────────────────────────────────────┘     │     │
│  └──────────────────────────────────────────────────┘    │
└────────────────────────────────────────────────────────────┘
```

| Layer | Primary control | Stops which escalation step |
|-------|-----------------|-----------------------------|
| **Code** | Dependency scanning, image signing + admission verify | The initial foothold (vulnerable dep) and the poisoned-image supply-chain path |
| **Container** | `securityContext` (non-root, drop caps, RO rootfs), seccomp, AppArmor | Container→node breakout; privilege escalation inside the pod |
| **Cluster** | RBAC, NetworkPolicy, Pod Security Admission, Kyverno/VAP, audit logging | Pod→cluster (tokens/RBAC), pod→pod/metadata (network), privileged-pod creation |
| **Cloud** | IAM scoping, metadata egress NetworkPolicy | Cluster→cloud-account breach via node credentials |

Read it top-down for an auditor ("where are my gaps?") and bottom-up for an attacker ("how far can I climb?"). Same table, opposite intent — the recurring theme of this course.

---

## Layer by layer — the shippable primitives

### 1. Network — `NetworkPolicy` default-deny (Module 06)

The segmentation layer. Start every namespace with a default-deny ingress+egress, re-allow DNS and the exact flows the workload needs, and block egress to `169.254.169.254` and the API server for workloads that never call it. Remember the caveat: only real if an enforcing CNI (Calico/Cilium) is installed.

### 2. Pod Security Admission — the `restricted` profile

PSA is the built-in admission controller (GA since 1.25) that enforces the Pod Security Standards. You opt a namespace in with labels; there is no sidecar, no CRD. Three modes — `enforce` (reject), `audit` (log), `warn` (client warning) — each pinned to a standards version:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: dojo-hardened
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.31
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/audit: restricted
```

The `restricted` profile is the one worth memorizing because it bundles most of the container-layer controls below into a single label. It requires: `runAsNonRoot: true`, `allowPrivilegeEscalation: false`, all capabilities dropped (`ALL`), a `seccompProfile` of `RuntimeDefault`, no host namespaces, no `privileged`, and `readOnlyRootFilesystem` is encouraged (enforced by `restricted` as of recent versions via the `baseline`→`restricted` deltas). The pragmatic rollout is `warn`+`audit` first to see what breaks, then flip `enforce`.

### 3. `securityContext` — the explicit container controls

Even with PSA, write the `securityContext` explicitly so the manifest *documents* its own posture and survives a namespace label being removed:

```yaml
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    fsGroup: 10001
    seccompProfile:
      type: RuntimeDefault          # see below
  containers:
    - name: app
      image: myapp:1.4.2            # pinned tag, never :latest
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]             # add back only the one or two you truly need
      volumeMounts:
        - { name: tmp, mountPath: /tmp }     # writable scratch for RO-rootfs apps
  volumes:
    - name: tmp
      emptyDir: {}
```

Each line maps to a boundary in the escalation chain:

| Field | What it stops |
|-------|---------------|
| `runAsNonRoot` / `runAsUser` | UID 0 in the container mapping to dangerous host operations after a breakout |
| `allowPrivilegeEscalation: false` | `setuid` binaries and `sudo`-style gains inside the container (sets `no_new_privs`) |
| `capabilities.drop: ["ALL"]` | `CAP_NET_RAW` packet spoofing, `CAP_SYS_ADMIN` mount tricks, etc. |
| `readOnlyRootFilesystem: true` | Attacker writing a webshell/binary into the image filesystem for persistence |
| `seccompProfile: RuntimeDefault` | ~44 dangerous syscalls (`ptrace`, `mount`, `keyctl`, `bpf`…) the app never uses |

### 4. seccomp `RuntimeDefault`

seccomp filters the syscalls a container may make. The single highest-value, lowest-risk setting is `RuntimeDefault` — the container runtime's curated blocklist of syscalls no normal app needs. It is **off by default** unless you set it (or PSA `restricted` forces it). For a bespoke profile you point at a JSON file under the kubelet's seccomp dir:

```yaml
seccompProfile:
  type: Localhost
  localhostProfile: profiles/audit.json   # relative to /var/lib/kubelet/seccomp
```

Start with `RuntimeDefault` everywhere; only build a `Localhost` profile when a specific workload needs a syscall `RuntimeDefault` blocks (rare) or you want to *tighten* further than the default.

### 5. AppArmor

AppArmor is the complementary MAC layer (path/file/capability confinement) on Debian/Ubuntu nodes. Since 1.30 it has a first-class field (previously an annotation):

```yaml
securityContext:
  appArmorProfile:
    type: RuntimeDefault      # or Localhost + localhostProfile: <name>
```

seccomp restricts *syscalls*; AppArmor restricts *what files/paths/capabilities* a process touches. They are not redundant — defense in depth means running both where the node supports it. On kind nodes AppArmor enforcement depends on the host; treat it as a production control you *validate* in the lab, not one you rely on kind to enforce.

### 6. Image provenance & scanning (the Code layer)

Two distinct controls, often conflated:

- **Scanning** — `trivy image myapp:1.4.2` (or Grype) catches known-vulnerable OS packages and language deps *before* they ship. Gate CI on it: fail the build on fixable HIGH/CRITICAL CVEs.
- **Provenance / signing** — `cosign sign` at build, then an admission policy *verifies* the signature at deploy so only images your pipeline built can run. This is what closes the typosquat/poisoned-base-image path. Pin by **digest** (`myapp@sha256:...`) in the most sensitive tiers so a tag can't be re-pointed under you.

```bash
trivy image --severity HIGH,CRITICAL --exit-code 1 myapp:1.4.2   # CI gate
cosign verify --key cosign.pub myapp:1.4.2                        # supply-chain gate
```

### 7. Admission policy — Kyverno / ValidatingAdmissionPolicy

RBAC says *who* can act; admission policy says *what* the resulting object may look like. This is where you enforce org-wide rules PSA can't express: "every image must come from `registry.internal/`," "no `:latest` tag," "every pod must set resource limits," "signatures must verify."

- **Kyverno** — CRD-based, YAML policies, the most common choice. Can validate, mutate (inject defaults), and generate (auto-create a default-deny NetworkPolicy per new namespace).
- **ValidatingAdmissionPolicy (VAP)** — the in-tree, CEL-based successor (GA 1.30). No external controller, no webhook latency/availability risk — the policy runs inside the API server.

```yaml
# Kyverno: forbid the :latest tag cluster-wide
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-latest-tag
spec:
  validationFailureAction: Enforce
  rules:
    - name: require-image-tag
      match:
        any:
          - resources:
              kinds: ["Pod"]
      validate:
        message: "An explicit image tag (not :latest) is required."
        pattern:
          spec:
            containers:
              - image: "!*:latest"
```

VAP for the same intent uses a CEL expression and binds to namespaces by label — prefer it for simple validations to avoid running a webhook on the critical path of every create.

### 8. Audit logging

Hardening you can't observe is hope. The API server audit log is the record of *who did what* — the thing you reach for after an incident and the thing that proves a control is working. Configure an audit policy (what to log, at which stage, at `Metadata`/`Request`/`RequestResponse` level) and ship it off-node. High-value events: `secrets` access, `create pods` with `privileged`, `exec` into pods, RBAC changes, anonymous requests. On managed clusters this is a provider setting; on self-managed it's `--audit-policy-file` + `--audit-log-path` on the API server.

### 9. CIS benchmark — `kube-bench` (concept)

The CIS Kubernetes Benchmark is the canonical "is my control plane and node configured sanely" checklist, and `kube-bench` is the scanner that scores a node against it. It maps 1:1 to real misconfigurations: anonymous auth on the kubelet, `--insecure-port`, missing audit flags, over-permissive file modes on `/etc/kubernetes`. Run it on any cluster you own and turn each FAIL into a line item. In this lab it's conceptual — kind's control plane runs flags you don't manage — but the *findings* it looks for are exactly the controls above.

---

## The consolidated hardening checklist

Run top to bottom. Each item names the control and the one command or field that proves it's on.

**Code / supply chain**
- [ ] Images scanned in CI; build fails on fixable HIGH/CRITICAL (`trivy image --exit-code 1`).
- [ ] Images signed (`cosign sign`) and verified at admission; sensitive tiers pinned by digest.
- [ ] No `:latest` anywhere — enforced by admission policy, not convention.

**Container**
- [ ] `runAsNonRoot: true` and a numeric non-zero `runAsUser`.
- [ ] `allowPrivilegeEscalation: false`.
- [ ] `capabilities.drop: ["ALL"]`; add back only what's proven necessary.
- [ ] `readOnlyRootFilesystem: true` with `emptyDir` scratch for the paths the app writes.
- [ ] `seccompProfile.type: RuntimeDefault` (or a tighter `Localhost` profile).
- [ ] AppArmor profile set where nodes support it.
- [ ] No `privileged`, no `hostNetwork/hostPID/hostIPC`, no `hostPath` to sensitive dirs.
- [ ] Resource `requests` and `limits` set (also a DoS control).

**Cluster**
- [ ] Namespace labelled `pod-security.kubernetes.io/enforce: restricted`.
- [ ] `automountServiceAccountToken: false` unless the pod genuinely calls the API.
- [ ] RBAC least-privilege; no wildcard verbs/resources; Secrets scoped with `resourceNames`.
- [ ] Default-deny `NetworkPolicy` (ingress+egress) in every namespace, on an **enforcing** CNI.
- [ ] Egress to `169.254.169.254` and the API server denied for workloads that don't need them.
- [ ] Admission policy (Kyverno/VAP) enforcing image source, tags, and signatures.
- [ ] Audit logging on, shipped off-node, alerting on Secret access / privileged pods / exec.
- [ ] Encryption-at-rest enabled for Secrets in etcd (Course 01's lesson).

**Cloud**
- [ ] Node IAM role scoped to the minimum; no broad `*` permissions.
- [ ] Metadata endpoint unreachable from pods (IMDSv2 + NetworkPolicy egress deny).
- [ ] `kube-bench` run; every FAIL triaged to a fix or an accepted-risk note.

A cluster that passes this list has no single misconfiguration that is catastrophic — which is the entire definition of defense in depth.

---

## Debugging a hardened pod that won't start

The hard part of hardening is not writing the controls — it's that tightening them *breaks working pods*, and the lazy fix is to loosen the control until the pod starts, which silently re-opens the hole. The discipline is: read the exact rejection, identify the *one* requirement the image violates, and satisfy it *the hardened way* (a numeric UID, a writable `emptyDir`, a single added capability) rather than reverting to root/privileged.

| Symptom | Likely cause | Fix (without re-opening the hole) |
|---------|--------------|-----------------------------------|
| Pod rejected at create: `violates PodSecurity "restricted"` | PSA `enforce` is on and the spec is missing required fields | Read the message — it lists every violated field; add each (`runAsNonRoot`, `seccompProfile`, dropped caps) |
| `CreateContainerConfigError: container has runAsNonRoot and image will run as root` | Image's default user is root (`USER` not set in Dockerfile) | Set `runAsUser: 10001` explicitly, or rebuild the image with a non-root `USER` — do **not** drop `runAsNonRoot` |
| App `CrashLoopBackOff` with `Read-only file system` / `EACCES` | `readOnlyRootFilesystem: true` but the app writes to `/tmp`, `/var/run`, a cache dir | Mount an `emptyDir` at each write path; keep the rootfs read-only |
| App crashes with `Operation not permitted` on a syscall | seccomp `RuntimeDefault` (or a capability drop) blocked a syscall the app legitimately needs | Identify the syscall/cap; add back the single `capability` or use a `Localhost` seccomp profile allowing just that call — not `Unconfined` |
| Pod won't start after `automountServiceAccountToken: false` | The app actually calls the K8s API and lost its token | Re-enable the token for *that* pod only and scope its RBAC tightly — don't blanket re-enable |
| `bind: permission denied` on a low port | Non-root can't bind <1024 and you dropped `NET_BIND_SERVICE` | Add back *only* `NET_BIND_SERVICE`, or (better) listen on a high port and map it at the Service |
| Everything green but Kyverno/VAP rejects deploy | Admission policy (image registry/tag/signature) not satisfied | Fix the image reference/signature to comply — the policy is doing its job |

### Diagnose each — the exact commands

**Read the PSA rejection in full — it is a complete to-do list:**

```bash
kubectl -n dojo-hardened apply -f pod.yaml
# Error ... violates PodSecurity "restricted:v1.31": allowPrivilegeEscalation != false,
#   unrestricted capabilities (container "app" must drop "ALL"),
#   runAsNonRoot != true, seccompProfile ...
```

Every clause after the colon is a field you must add. Don't guess — the admission plugin already told you exactly what's missing.

**Dry-run against the profile before you ship**, so you learn the violations without a failed rollout:

```bash
# warn mode surfaces every violation as a client warning without blocking:
kubectl label ns dojo-hardened pod-security.kubernetes.io/warn=restricted --overwrite
kubectl -n dojo-hardened apply -f pod.yaml --dry-run=server
```

**Find which write path a read-only rootfs is blocking:**

```bash
kubectl -n dojo-hardened logs deploy/app --previous | grep -iE 'read-only|permission denied|EACCES'
# e.g. nginx: [emerg] ... /var/cache/nginx ... -> mount an emptyDir there
```

**Find the syscall seccomp is killing** (the honest way — audit, don't disable):

```bash
# Temporarily run the pod with an AUDIT (not Unconfined) seccomp profile that logs
# every blocked syscall, read the node's audit log, then write a Localhost profile
# that allows exactly those. Never ship Unconfined to "fix" it.
docker exec dojo-worker sh -c 'grep SECCOMP /var/log/audit/audit.log | tail' 2>/dev/null \
  || echo "no auditd on node — use a Localhost audit profile + kubelet logs"
```

**Confirm the image's default user before blaming the manifest:**

```bash
docker image inspect myapp:1.4.2 --format '{{.Config.User}}'   # empty = root → set runAsUser
```

> **War story.** Hardening the LGTM ingest tier at SAP, I flipped a namespace to PSA `enforce: restricted` and three of five Deployments went straight to `CreateContainerConfigError`. The quick "fix" circulating in the team chat was to drop the namespace back to `baseline` — which would have silently un-done the whole project. Instead we read the rejections one at a time. Two pods just needed `runAsUser: 10001` because their base images defaulted to root with no `USER` line. The third was Promtail, which crashed on `readOnlyRootFilesystem` because it writes a positions file to `/tmp` and its WAL to a data dir — so it needed two `emptyDir` mounts, not a loosened rootfs. The last one failed seccomp on a single syscall; the "fix" someone proposed was `seccompProfile: Unconfined`, which throws away the entire control. The real fix was a `Localhost` profile that allowed exactly that one call on top of `RuntimeDefault`. Net result: all five ran under `restricted`, zero controls were loosened, and the incident that originally motivated the work — a dependency CVE that would have let an attacker write a binary into the container — was now dead on arrival because the rootfs was read-only and caps were dropped. Lesson: **every time a hardened pod won't start, the control is telling you something true about the workload. Satisfy it; don't silence it.**

---

## Checkpoint

You're ready to call a cluster hardened when you can, without looking anything up:

1. Recite the 4 C's and name the shippable Kubernetes primitive that hardens each layer.
2. Label a namespace for Pod Security Admission `restricted` enforcement, and name the rollout order (`warn`/`audit` → `enforce`) and why.
3. Write a `securityContext` from memory that is non-root, drops all caps, has a read-only rootfs with writable scratch, disallows privilege escalation, and sets `RuntimeDefault` seccomp.
4. Explain the difference between seccomp and AppArmor, and why running both is not redundant.
5. Distinguish image *scanning* from image *provenance/signing*, and name the control that verifies a signature at deploy time.
6. State when to reach for Kyverno versus ValidatingAdmissionPolicy, and give one policy each enforces.
7. Explain what audit logging proves and name three high-value events to alert on.
8. Say what `kube-bench`/CIS gives you and how a FAIL becomes a checklist item.
9. Given a pod rejected by PSA `restricted`, read the rejection and fix every violation *without* dropping to root or `privileged`.
10. Given a `CrashLoopBackOff` on a read-only rootfs or a blocked syscall, fix it the hardened way (`emptyDir` / single added cap / `Localhost` seccomp profile) instead of re-opening the control.

➡ That's the course. You traced the escalation chain from a compromised pod to the cloud account, and you placed a control on every link. The final skill — the one that makes all of this real — is the one you just practiced: hardening without breaking the workload, and reading each failure as the control doing its job.
