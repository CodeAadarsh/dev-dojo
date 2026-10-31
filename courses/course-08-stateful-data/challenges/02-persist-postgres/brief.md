# Persist Postgres

An engineer on the platform team deployed Postgres for a new internal service. It worked great in dev. Then the on-call engineer restarted the pod to pick up a config change — and **all tables were gone**. The deployment used `emptyDir` for the data directory: a volume that exists only for the lifetime of a pod and is silently wiped on every restart.

Your task is to deploy Postgres correctly: backed by a PVC so data survives pod restarts, configured via a Secret (not hardcoded env vars), and exposed via a ClusterIP Service. Then *prove* it works by writing a row, killing the pod, and reading the row back.

## Target state

Namespace: `dojo-db`. The verifier accepts your solution when **all** of the following hold:

1. **A Deployment** (or StatefulSet) whose first container image contains `postgres`.
2. **A volumeMount** at exactly `/var/lib/postgresql/data` backed by a `persistentVolumeClaim` volume (not `emptyDir`, not `hostPath`).
3. **A Bound PVC** in `dojo-db` — the backing store for that mount.
4. **≥ 1 readyReplica** — Postgres is up and passing its readiness check.

> The verifier does **not** check that the Secret exists, but the pod won't start without valid `POSTGRES_PASSWORD` — so you must create one.

## Prove persistence (do this before running the verifier)

```bash
# Write a row
kubectl exec -n dojo-db deploy/postgres -- \
  psql -U dojouser -d dojoapp -c \
  "CREATE TABLE IF NOT EXISTS dojo_test (id serial, note text);
   INSERT INTO dojo_test(note) VALUES('survived');"

# Delete the pod — the Deployment restarts it with the same PVC
kubectl delete pod -n dojo-db -l app=postgres

# Wait for it to come back
kubectl rollout status deploy/postgres -n dojo-db

# Re-read — row must be present
kubectl exec -n dojo-db deploy/postgres -- \
  psql -U dojouser -d dojoapp -c "SELECT * FROM dojo_test;"
```

If the row survives, your PVC is doing its job.

## Why this matters

`emptyDir` is not a bug — it is correct for caches, scratch space, and anything truly ephemeral. The bug is using it for a data directory that is supposed to outlive the pod. Kubernetes gives you zero indication at apply time that you've made this mistake; the cluster happily creates the Deployment, the pod starts, and data is silently lost on every restart.

Putting Postgres credentials in a Secret (not in the Deployment spec as plain env) is the second lesson: anything in `spec.template.spec.containers[*].env[*].value` is readable in `kubectl get deploy -o yaml` by anyone with `get` on Deployments. A Secret at least requires `get secret` permission, and it can be locked down independently or rotated without touching the Deployment.
