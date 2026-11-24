# Volume Leakage

**Day 3 of the incident.** The on-call engineer is staring at a counter app that keeps resetting to zero every time the pod restarts. Users are frustrated. The team swears the app writes data correctly. And they're right — it does write. It writes to `/data/count.txt` on every run. But every restart wipes the count back to zero.

The bug isn't in the application code. It's in how the container is wired up.

---

## Why this matters

When a container writes a file, it goes into the **container's writable layer** — an ephemeral, copy-on-write overlay that sits on top of the read-only image layers. This layer lives only as long as the container process. The moment the container restarts (even inside the same pod), that writable layer is recreated fresh from the image. All writes are gone.

The fix is a **Volume** — a piece of storage that exists outside the container's ephemeral layer. With a volume mounted at `/data`, writes survive container restarts because the data lives in a directory managed by Kubernetes, not inside the container.

```
Without volume:                     With emptyDir volume:

  container layer (ephemeral)          emptyDir (pod-scoped, survives restart)
       /data/count.txt ✗                    /data/count.txt ✓
  RESTART → layer wiped → 0           RESTART → emptyDir survives → count kept
```

---

## Mission

Fix the `counter` Deployment in namespace `dojo-docker-volume` so that `/data/count.txt` persists across container restarts.

**The verifier checks:**

1. The Deployment `counter` has at least one Volume defined in `spec.template.spec.volumes`
2. The container has a VolumeMount at `/data` in `spec.template.spec.containers[0].volumeMounts`
3. At least one pod for the Deployment is in `Running` state

---

## Rules

- Work only in namespace `dojo-docker-volume`
- An `emptyDir` volume is sufficient — the verifier does not require a PVC
- After patching, do a rollout restart: `kubectl rollout restart deployment counter -n dojo-docker-volume`

When all checks pass, run the verifier:

```bash
bash courses/course-37-docker-internals/challenges/09-volume-leakage/verify.sh
```
