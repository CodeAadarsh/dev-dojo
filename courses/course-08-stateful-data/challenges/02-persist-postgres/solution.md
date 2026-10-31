# Solution — Persist Postgres

Four objects, applied in order. The Secret must exist before the Deployment starts — pods won't schedule if `secretRef` points at a missing Secret.

```yaml
# 01-postgres-secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: postgres-secret
  namespace: dojo-db
type: Opaque
stringData:
  POSTGRES_DB: dojoapp
  POSTGRES_USER: dojouser
  POSTGRES_PASSWORD: super-secret-pw-42
---
# 02-postgres-pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-data
  namespace: dojo-db
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: standard
  resources:
    requests:
      storage: 2Gi
---
# 03-postgres-deploy.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres
  namespace: dojo-db
  labels:
    app: postgres
spec:
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
        - name: postgres
          image: postgres:16-alpine
          ports:
            - containerPort: 5432
          envFrom:
            - secretRef:
                name: postgres-secret
          volumeMounts:
            - name: pgdata
              mountPath: /var/lib/postgresql/data
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 256Mi
          readinessProbe:
            exec:
              command: ["pg_isready", "-U", "dojouser", "-d", "dojoapp"]
            initialDelaySeconds: 5
            periodSeconds: 10
            failureThreshold: 6
      volumes:
        - name: pgdata
          persistentVolumeClaim:
            claimName: postgres-data
---
# 04-postgres-svc.yaml
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: dojo-db
spec:
  selector:
    app: postgres
  ports:
    - port: 5432
      targetPort: 5432
  type: ClusterIP
```

Apply and verify:

```bash
kubectl apply -f 01-postgres-secret.yaml
kubectl apply -f 02-postgres-pvc.yaml
kubectl apply -f 03-postgres-deploy.yaml
kubectl apply -f 04-postgres-svc.yaml
kubectl -n dojo-db rollout status deploy/postgres
```

Then prove persistence (do this before verify.sh):

```bash
# Write a row
kubectl exec -n dojo-db deploy/postgres -- \
  psql -U dojouser -d dojoapp -c \
  "CREATE TABLE IF NOT EXISTS dojo_test (id serial, note text);
   INSERT INTO dojo_test(note) VALUES('survived');"

# Kill the pod (Deployment restarts it, PVC reattaches automatically)
kubectl delete pod -n dojo-db -l app=postgres

# Wait for the replacement pod to become Ready
kubectl rollout status deploy/postgres -n dojo-db

# Re-read — row must still be there
kubectl exec -n dojo-db deploy/postgres -- \
  psql -U dojouser -d dojoapp -c "SELECT * FROM dojo_test;"

# Now run the verifier
bash courses/course-08-stateful-data/challenges/02-persist-postgres/verify.sh
```

## Why each piece matters

- **`envFrom.secretRef`** — all three `POSTGRES_*` keys land in the container environment without any of them appearing in the Deployment spec or pod spec YAML. Anyone with `get deployment` sees only `secretRef.name: postgres-secret`, not the password. Contrast with `env[*].value: "hardcoded"` which is in plaintext in every `kubectl get deploy -o yaml`.
- **`volumeMounts[0].mountPath: /var/lib/postgresql/data`** — postgres stores its data directory here by default. Mount anything else and postgres initialises a *new* cluster in the container's own tmpfs. The pod starts, postgres is happy, but no data survives a restart. The path must be exact.
- **`volumes[0].persistentVolumeClaim.claimName: postgres-data`** — this links the named volume to the PVC. Swap this for `emptyDir: {}` and the mount path is satisfied (no error) but the volume lives and dies with the pod. The Deployment spec accepts both; only the runtime behavior differs.
- **`readinessProbe: pg_isready`** — this probe only passes when Postgres is accepting connections on the right database. `initialDelaySeconds: 5` gives Postgres time to initialise on first run (directory scan + WAL setup). Without a probe, the Service endpoint is marked ready at pod start, before Postgres is actually accepting queries.

## Security note — what an attacker sees

```bash
# Anyone with get-secret in dojo-db can read all credentials in plaintext
kubectl get secret postgres-secret -n dojo-db \
  -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d
```

This is why `get secret` RBAC permission should be restricted to the minimum: the postgres pod itself (via ServiceAccount token projection) and the ops/incident-response team. The next hardening step is an external secrets manager (Vault, AWS Secrets Manager via ESO) that rotates credentials without touching a Kubernetes Secret at all.
