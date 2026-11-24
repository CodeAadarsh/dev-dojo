# Distroless Debug

**The alert fires at 2 AM.** The `api` pod in `dojo-docker-distroless` is in `CrashLoopBackOff`. You look at the logs: `exit status 1`. Nothing else. You try the classic:

```bash
kubectl exec -n dojo-docker-distroless deploy/api -- sh
```

```
OCI runtime exec failed: exec failed: unable to start container process:
error loading shared libraries: exec: "sh": not found in $PATH
```

No shell. No package manager. No `ls`. No `cat`. It's a **distroless image** — it ships only the application binary and its runtime libraries. Nothing else. This is intentional (smaller attack surface) but it makes debugging non-obvious.

The secret weapon: **ephemeral containers**. Kubernetes lets you inject a debug container (`busybox`, `ubuntu`, whatever) alongside a running container, sharing its PID and network namespaces. You can run `env`, `strace`, `curl` — anything — without modifying the application image.

---

## Why this matters

Distroless images are increasingly common in production. `gcr.io/distroless/` images are used by Google, Shopify, and many security-conscious teams because:

- No shell = an attacker who gets RCE can't easily run `curl | sh`
- No package manager = nothing to install post-exploit
- Smaller image = fewer CVEs

But "can't exec in" is a real operational constraint. The right tool is `kubectl debug`, not adding a shell back to the image.

---

## Mission

The `api` Deployment in `dojo-docker-distroless` is crashlooping because of a bad configuration value. Use an ephemeral container to diagnose the problem, then fix it.

**The verifier checks:**

1. ConfigMap `app-config` in `dojo-docker-distroless` does **not** contain `wrong-host` in its `DATABASE_URL` value
2. At least one pod for Deployment `api` is in `Running` state

Run the verifier:

```bash
bash courses/course-37-docker-internals/challenges/11-distroless-debug/verify.sh
```
