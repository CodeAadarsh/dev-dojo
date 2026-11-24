# Challenge 12 — Admission Gauntlet

**Difficulty:** Hard | **Type:** Verifier | **Est. Time:** 75 min

---

## Situation

Five attack patterns. Five policies to write. All five must be blocked.

Your cluster's admission control is a blank slate. No Kyverno policies exist yet. An attacker will attempt each of these patterns:

| # | Pattern | Why it's dangerous |
|---|---------|-------------------|
| 1 | `privileged: true` container | Full host access |
| 2 | `hostPath: /` or `/etc` mount | Read host filesystem |
| 3 | Container runs as root (UID 0) | Write access to mounted secrets |
| 4 | No CPU/memory limits | DoS the node |
| 5 | Image tagged `:latest` | Non-reproducible, can be swapped |

Write Kyverno ClusterPolicies (or OPA Gatekeeper ConstraintTemplates) that block all five. Then create the evidence ConfigMap to record your work.

---

## Lab Setup

```bash
bash courses/course-38-redblue-security/challenges/12-admission-gauntlet/setup.sh
```

This creates the namespace `dojo-sec-gauntlet` and installs Kyverno if not present.

---

## Your Goal

1. Write and apply a policy for each of the 5 attack patterns
2. Verify each policy blocks a dry-run of the corresponding attack pod
3. Record your results:

```bash
kubectl create configmap policy-evidence \
  -n dojo-sec-gauntlet \
  --from-literal=privileged=blocked \
  --from-literal=hostpath=blocked \
  --from-literal=root-user=blocked \
  --from-literal=no-limits=blocked \
  --from-literal=latest-tag=blocked
```

---

## Verifier

```bash
bash courses/course-38-redblue-security/challenges/12-admission-gauntlet/verify.sh
```

---

## What You'll Learn

- Kyverno ClusterPolicy structure: `match`, `validate`, `deny` rules
- OPA Rego and ConstraintTemplate basics
- Policy-as-code principles: shift admission control left
- Why admission webhooks are the last line of defense before a pod runs
