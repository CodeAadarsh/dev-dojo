# Harden the Pod, CKS-Style

The `secure-app` Deployment in namespace `dojo-cks` runs wide open — root, full capabilities, writable root filesystem, privilege escalation allowed. Your job is the CKS bread-and-butter: harden it to the `restricted` bar **and keep it Running**.

## Mission

Edit the `secure-app` Deployment so its container runs with **all** of these:

| Field | Value |
|-------|-------|
| `runAsNonRoot` | `true` |
| `runAsUser` | `1000` (any non-zero) |
| `allowPrivilegeEscalation` | `false` |
| `readOnlyRootFilesystem` | `true` |
| `capabilities.drop` | `["ALL"]` |
| `seccompProfile.type` | `RuntimeDefault` |

The Deployment must still have **≥1 Ready replica** after hardening. (The workload is a `busybox:1.36` sleep loop — it writes nothing, so a read-only root filesystem won't break it. In the real world you'd add an `emptyDir` for any writable path the app needs — see the solution.)

## Memorize this block

That six-field securityContext is the single most reused answer on CKS. Burn it into muscle memory — you'll type it under time pressure on the exam and in every hardened manifest at work.

Run the verifier once `secure-app` is hardened and Ready.
