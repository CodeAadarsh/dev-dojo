# Solution: Entrypoint Trap

## Step 1 — Diagnose

```bash
kubectl describe pod -n dojo-docker-entrypoint -l app=web
```

Look at the **Command** and **Args** fields:
```
Command:
  /bin/sh
Args:
  (none)
```

`/bin/sh` with no `-c "command"` and no script file just starts an interactive shell. Since there's no terminal attached, it exits immediately with code 0. Kubernetes sees a healthy exit, waits a bit, and restarts it. The backoff timer increases each time.

## Step 2 — Fix Option A: Remove the override (simplest)

The `nginx:1.27-alpine` image already has the correct `ENTRYPOINT` and `CMD` baked in. Remove the broken `command:` override and let the image do its job:

```bash
kubectl patch deployment web -n dojo-docker-entrypoint \
  --type=json \
  -p='[{"op":"remove","path":"/spec/template/spec/containers/0/command"},{"op":"remove","path":"/spec/template/spec/containers/0/args"}]'
```

## Step 3 — Fix Option B: Set it explicitly (more educational)

```bash
kubectl patch deployment web -n dojo-docker-entrypoint \
  --type=json \
  -p='[
    {"op":"replace","path":"/spec/template/spec/containers/0/command","value":["/docker-entrypoint.sh"]},
    {"op":"replace","path":"/spec/template/spec/containers/0/args","value":["nginx","-g","daemon off;"]}
  ]'
```

## Step 4 — Verify

```bash
kubectl get pods -n dojo-docker-entrypoint
bash courses/course-37-docker-internals/challenges/03-entrypoint-trap/verify.sh
```

**Flag:** `KUBE{entrypoint_runs_cmd_as_args}`

## The Full ENTRYPOINT/CMD Explanation

In a Dockerfile:
- `ENTRYPOINT ["nginx"]` — the executable. This is what actually runs.
- `CMD ["-g", "daemon off;"]` — default arguments passed to ENTRYPOINT.

In a Kubernetes Pod spec:
- `command:` — overrides `ENTRYPOINT` from the image
- `args:` — overrides `CMD` from the image

The mental model: `ENTRYPOINT` is the verb, `CMD` is the noun. The Pod runs `<ENTRYPOINT> <CMD>`. When you override `command:` in the Pod spec, you replace the verb entirely.

```
Image ENTRYPOINT: ["nginx"]
Image CMD: ["-g", "daemon off;"]
Pod command: ["/bin/sh"]   ← replaces nginx
Pod args: []               ← nothing to execute with /bin/sh → exits
```

**Always use exec form** (`["nginx", "-g", "daemon off;"]`) not shell form (`nginx -g "daemon off;"`) in Dockerfiles. Shell form wraps the command in `/bin/sh -c`, which means your app is PID 2 and won't receive signals cleanly — `kubectl rollout restart` will hang waiting for SIGTERM.
