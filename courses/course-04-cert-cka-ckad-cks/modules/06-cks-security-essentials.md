# CKS: Security Essentials

> **Module 06 · Course 04** — CKS assumes you already have the CKA. It's about *locking down* a working cluster, and it's heavily time-pressured and practical. This module is the hardening checklist the exam (and real production) rewards. Each item maps to a Course-01 or Course-03 challenge where you did it hands-on.

## The 4 C's

Security is layered: **Cloud → Cluster → Container → Code**. You can't fix a bad container with a good cluster policy, and vice-versa. CKS touches all four, but cluster+container are the bulk.

## The hardening checklist

### 1. Pod Security Admission (PSA)
Built-in. Label a namespace to enforce a standard:

```bash
kubectl label ns app \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/warn=restricted
```

`restricted` forbids privilege escalation, running as root, host namespaces, most capabilities. (Hands-on: Course 01 → *Lock the Namespace*.)

### 2. SecurityContext (the compliant pod)

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities: { drop: ["ALL"] }
  seccompProfile: { type: RuntimeDefault }
```

That block is worth memorizing cold — it's the answer to half of CKS's workload-hardening tasks.

### 3. NetworkPolicy
Default-deny, then whitelist. (Course 03 → *Shut the Flat Network*.) Limits lateral movement after a breach.

### 4. RBAC least privilege
No wildcard verbs/resources, no `cluster-admin` bindings, never grant `bind`/`escalate`. Audit with `kubectl auth can-i --list --as=...`. (Course 01 → *The Over-Privileged Account*.)

### 5. Secrets at rest
Secrets are base64, **not** encrypted. Enable `EncryptionConfiguration` (aescbc/KMS) on the api-server. (Course 01 → *base64 Is Not Encryption*; Course 03 → *Straight From etcd*.)

### 6. Supply chain
Scan images (`trivy image nginx:1.27-alpine`), pin by **digest** not tag, use minimal/distroless bases, verify provenance, run `kube-bench` (CIS) and `kube-linter`.

### 7. Runtime
`seccompProfile: RuntimeDefault` by default; AppArmor profiles for sensitive workloads; Falco for runtime anomaly detection; audit logging on the api-server.

### 8. Admission policy
`ValidatingAdmissionPolicy` (built-in CEL) or Kyverno/OPA Gatekeeper to enforce org rules (no `:latest`, required labels, no privileged). (Course 05 → *Ban the Latest*.)

## Debugging hardened workloads

The hard part of CKS isn't applying policy — it's that policy **breaks the app**, and you must fix it *without* re-opening the hole.

| Symptom | Cause | Fix (keep it secure) |
|---------|-------|---------------------|
| Pod rejected: `violates PodSecurity "restricted"` | missing securityContext fields | add the compliant block above |
| App crashes: `read-only file system` | `readOnlyRootFilesystem: true` | mount an `emptyDir` at the writable path (e.g. /tmp) |
| App crashes: `permission denied` on port <1024 | `runAsNonRoot` | use a high port + change the container config |
| `exec format` / cap errors | dropped a capability the app needs | add back only the *one* cap, not ALL |

```bash
kubectl describe pod <p>          # PSA rejection reason is in the event / error
kubectl logs <p>                   # "read-only file system" etc.
```

> **War story:** enforcing `restricted` broke an nginx image that writes its pid to `/var/run` and cache to `/var/cache/nginx`. The fix wasn't to drop the policy — it was two `emptyDir` mounts for those paths plus `readOnlyRootFilesystem: true`. Secure *and* running.

## Checkpoint

1. Recite the compliant `securityContext` block from memory.
2. Label a namespace to enforce PSA `restricted`.
3. Given `violates PodSecurity "restricted"`, name three fields you'd add.
4. Explain why a hardened pod hits `read-only file system` and the secure fix.
5. Name two supply-chain controls (scanning, digests, distroless, kube-bench).

➡ Next: **Exam-Day Strategy** — turning this knowledge into a passing score.
