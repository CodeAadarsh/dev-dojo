# Entrypoint Trap

It's 3 AM. The monitoring alert says pod `web` in `dojo-docker-entrypoint` is in `CrashLoopBackOff`. You SSH in, check the logs — **nothing**. No error message. No stack trace. Just exit code 0.

Exit code 0 means success. But the container isn't running. Something is starting, finishing immediately, and Kubernetes keeps restarting it like it's broken — because it is.

Someone confused `ENTRYPOINT` and `CMD`. The container runs a shell with no arguments, the shell exits cleanly, and Kubernetes restarts it forever.

## Mission

Fix the Deployment `web` in namespace `dojo-docker-entrypoint` so the container stays Running. The verifier checks:

1. Deployment `web` exists in `dojo-docker-entrypoint`
2. At least one pod is in `Running` state
3. The pod has been Running for at least 10 seconds (not just restarting)

## The ENTRYPOINT vs CMD Matrix

This trips up almost everyone at some point. Here's the full picture:

```
Dockerfile has:              Container gets:
──────────────────────────   ──────────────────────────────────────
ENTRYPOINT ["nginx"]         Runs: nginx
CMD ["-g", "daemon off;"]    Runs: nginx -g "daemon off;"

ENTRYPOINT + CMD together    Runs: <ENTRYPOINT> <CMD args>
command: in Pod spec         Overrides ENTRYPOINT entirely
args: in Pod spec            Overrides CMD entirely
```

The broken deployment sets `command: ["/bin/sh"]` with no `args`. So the container runs `/bin/sh` with no `-c "..."` flag — the shell starts, finds nothing to do, and exits immediately with code 0.

## Setup

```bash
bash courses/course-37-docker-internals/challenges/03-entrypoint-trap/setup.sh
```

## Verifying

```bash
bash courses/course-37-docker-internals/challenges/03-entrypoint-trap/verify.sh
```
