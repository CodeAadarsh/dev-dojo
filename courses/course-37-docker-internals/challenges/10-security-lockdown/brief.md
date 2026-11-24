# Security Lockdown

A routine security scan flagged the `app` Deployment in `dojo-docker-security` as **Critical severity**. The finding: the container runs as root, has the full Linux capability set, writes freely to its own filesystem, and can escalate privileges.

This is the default state for most containers that never had a security review. It's also a gift to any attacker who lands a code execution bug in your app.

The CIS Docker Benchmark and Kubernetes Pod Security Standards both require four things before a container is considered hardened:

1. **Non-root**: The process must not run as UID 0
2. **No privilege escalation**: The process can never gain more privileges than it started with
3. **Read-only root filesystem**: The container cannot write to its own overlay layer
4. **Capabilities dropped**: Linux capabilities (the fine-grained root powers) must be dropped to the minimum

Your job is to apply all four to the `app` Deployment.

---

## Why these four matter

**Non-root** means that if an attacker escapes the app sandbox, they land as an unprivileged user instead of root. Combined with read-only filesystem, they can't install tools or write malware.

**No privilege escalation** (`allowPrivilegeEscalation: false`) sets the `no_new_privs` bit via `prctl(PR_SET_NO_NEW_PRIVS)`. This prevents `setuid` binaries from gaining root — an entire class of local privilege escalation is closed.

**Read-only root filesystem** (`readOnlyRootFilesystem: true`) makes the OverlayFS upperdir read-only. An attacker who gets RCE can run commands but cannot write `curl | sh` output, install backdoors, or modify binaries in-place. The writable layer is gone; only explicit Volume mounts can be written to.

**Drop ALL capabilities** removes Linux capabilities like `CAP_NET_RAW` (raw sockets for sniffing), `CAP_SYS_ADMIN` (most privileged capability), and 35 others. A container that only serves HTTP needs zero of them.

---

## Mission

Apply all four hardening measures to Deployment `app` in `dojo-docker-security`.

**The verifier checks all of these:**

1. `spec.template.spec.securityContext.runAsNonRoot` = `true`
2. `spec.template.spec.containers[0].securityContext.allowPrivilegeEscalation` = `false`
3. `spec.template.spec.containers[0].securityContext.readOnlyRootFilesystem` = `true`
4. `spec.template.spec.containers[0].securityContext.capabilities.drop[0]` = `ALL`
5. At least one pod is in `Running` state

> **Watch out:** nginx writes to `/var/cache/nginx` and `/var/run/nginx.pid` at startup. With `readOnlyRootFilesystem: true`, it will crash unless you give it writable Volume mounts at those paths. The solution covers this.

Run the verifier:

```bash
bash courses/course-37-docker-internals/challenges/10-security-lockdown/verify.sh
```
