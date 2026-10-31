# Lock the Namespace

PodSecurityPolicy died in v1.25. The team never replaced it, and a security audit just found the proof: namespace `dojo-psa` is running the `api` workload as a **privileged, root, no-seccomp** container — a single `kubectl exec` away from owning the node it lands on. There is no admission control stopping the next engineer from shipping the same thing.

Your job: turn on the **built-in Pod Security Admission (PSA)** controller for this namespace at the strictest level, then refactor the workload so it actually survives that gate. A policy nobody can comply with gets `--overwrite`-reverted by the first person it blocks; a policy with a compliant reference workload sticks.

## Background — the three standards, the three modes

PSA is a built-in admission controller (GA since v1.25, on by default). You configure it declaratively with **namespace labels** — no webhook, no operator, no CRDs. Two axes:

**The standard** (what is allowed), from loosest to tightest:

| Standard | Allows | Blocks |
|----------|--------|--------|
| `privileged` | everything | nothing (opt-out) |
| `baseline` | most workloads | privileged, hostPath, hostNetwork, hostPID, added caps beyond a safe set |
| `restricted` | hardened pods only | the above **plus** root, no-seccomp, writable escalation, any non-dropped caps |

**The mode** (what happens on violation):

```
   label key                                   effect on a violating pod
   ────────────────────────────────────────    ─────────────────────────
   pod-security.kubernetes.io/enforce=...   →   REJECTED at admission (never scheduled)
   pod-security.kubernetes.io/warn=...      →   admitted, warning printed to the kubectl client
   pod-security.kubernetes.io/audit=...     →   admitted, event written to the audit log
```

Enforce is checked **only at pod create/update** — relabeling a namespace does **not** evict pods already running. That asymmetry is the whole operational story of a PSA rollout: you set `warn`/`audit` first to find out what breaks, *then* flip `enforce`.

## What `restricted` actually demands

For the `api` container to be admitted under `enforce=restricted`, every one of these must hold (this is the exact checklist the verifier mirrors):

| Field | Required value | Why |
|-------|----------------|-----|
| `securityContext.runAsNonRoot` | `true` | a root process that escapes the container is root on the node |
| `securityContext.allowPrivilegeEscalation` | `false` | blocks `setuid`/`setcap` from regaining privileges |
| `securityContext.capabilities.drop` | includes `ALL` | start from zero Linux capabilities, add back nothing |
| `securityContext.seccompProfile.type` | `RuntimeDefault` (or `Localhost`) | filters dangerous syscalls (the default profile blocks ~44 of them) |
| `securityContext.privileged` | absent / `false` | privileged = all caps + all devices + no seccomp = node root |

`seccompProfile` and `runAsNonRoot` may be set at the **pod** `securityContext` (inherited by all containers) or per **container**; the rest are container-only.

## Mission / target state

The verifier accepts your work only when **all** of these are true:

1. Namespace `dojo-psa` carries `pod-security.kubernetes.io/enforce=restricted`.
2. It **also** carries `warn=restricted` and `audit=restricted` (defence in depth — a future namespace clone keeps the warnings even if someone loosens enforce).
3. Deployment `api` has a container that sets `runAsNonRoot: true`, `allowPrivilegeEscalation: false`, drops `ALL` capabilities, and uses the `RuntimeDefault` seccomp profile.
4. Deployment `api` has `readyReplicas >= 1` — i.e. a compliant pod is actually **Running**, which is the only real proof the policy is satisfiable.

## Rules of engagement

- Work in namespace `dojo-psa` (setup script creates it and plants the bad workload).
- The planted `api` uses `nginx:1.27-alpine`, which runs its master process as **root** and binds port **80** — it *cannot* satisfy `runAsNonRoot` no matter what `securityContext` you bolt on. Part of the lesson is recognising that and swapping to an unprivileged image (`nginxinc/nginx-unprivileged:1.27-alpine`, which runs as uid 101 and binds **8080**). Changing the image is expected, not cheating.
- Relabel the namespace with `kubectl label ns ... --overwrite`, and apply the hardened workload however you like (`kubectl apply`, `kubectl edit`). The verifier only inspects final state.

When the cluster is in the target state, run the verifier. It prints the flag only if every check passes.
