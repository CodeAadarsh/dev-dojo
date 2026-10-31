# Solution — Wire It Up

Create the inputs imperatively, then wire them into a Deployment.

```bash
kubectl -n dojo-wire create configmap app-config \
  --from-literal=APP_MODE=prod --from-literal=LOG_LEVEL=info

kubectl -n dojo-wire create secret generic app-secret \
  --from-literal=api-key=s3cr3t
```

```yaml
# app.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app
  namespace: dojo-wire
  labels: { app: app }
spec:
  replicas: 1
  selector:
    matchLabels: { app: app }
  template:
    metadata:
      labels: { app: app }
    spec:
      volumes:
        - name: secret-vol
          secret:
            secretName: app-secret
      containers:
        - name: web
          image: nginx:1.27-alpine
          envFrom:
            - configMapRef:
                name: app-config        # every CM key becomes an env var
          volumeMounts:
            - name: secret-vol
              mountPath: /etc/secret     # each Secret key becomes a file here
              readOnly: true
```

```bash
kubectl apply -f app.yaml
kubectl -n dojo-wire rollout status deploy/app

# prove the wiring:
kubectl -n dojo-wire exec deploy/app -- printenv APP_MODE LOG_LEVEL   # from the ConfigMap
kubectl -n dojo-wire exec deploy/app -- cat /etc/secret/api-key       # from the Secret file

bash courses/course-04-cert-cka-ckad-cks/challenges/07-ckad-config-wiring/verify.sh
```

## Why this shape

- **`envFrom` vs `env`:** `envFrom` injects *every* key of the ConfigMap as an env var in one line; `env` + `valueFrom.configMapKeyRef` picks a single key (and lets you rename it). Use `envFrom` when you want the whole map.
- **Secret as a file, not env:** mounting at `/etc/secret` gives one file per key (`/etc/secret/api-key`). This is the preferred way to hand secrets to apps — files can be `tmpfs`-backed, don't leak into the environment of child processes, don't show up in `kubectl describe`, and (unlike env) **update in place** when the Secret changes.
- **Fail-fast coupling:** if the ConfigMap or Secret doesn't exist, the pod won't start (`CreateContainerConfigError`) — which is why the verifier's "Ready" check implicitly proves both objects exist and are correctly referenced.
