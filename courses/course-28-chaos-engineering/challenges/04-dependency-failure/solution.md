# Solution — Dependency Failure: Graceful Degradation

The fix is two parts: decouple the readinessProbe from the backend, and add nginx fallback logic so the app serves a degraded response rather than a 502 when the backend is down.

## Minimal fix (decouples the probe only)

Change the readinessProbe from an `exec` that calls `backend-svc` to an `httpGet` that checks the app's own nginx process:

```bash
kubectl -n dojo-chaos-dep patch deploy app --type=json -p='[
  {
    "op": "replace",
    "path": "/spec/template/spec/containers/0/readinessProbe",
    "value": {
      "httpGet": {"path": "/", "port": 80},
      "initialDelaySeconds": 3,
      "periodSeconds": 5,
      "failureThreshold": 2
    }
  },
  {
    "op": "add",
    "path": "/spec/template/spec/containers/0/resources",
    "value": {
      "requests": {"cpu": "50m", "memory": "32Mi"},
      "limits": {"cpu": "200m", "memory": "64Mi"}
    }
  }
]'
```

This is enough for the verifier to pass. The probe now answers "is nginx accepting connections?" — independent of any upstream.

## Full fix (decouples probe + adds application-level fallback)

The minimal fix keeps the app Ready, but requests that reach the app while backend is down will still get a 502 from nginx's default proxy behaviour. The full fix adds a `/healthz` endpoint and a fallback response:

```bash
# Step 1: create a ConfigMap with a custom nginx config
kubectl -n dojo-chaos-dep apply -f - <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-nginx-conf
  namespace: dojo-chaos-dep
data:
  default.conf: |
    server {
        listen 80;

        location /healthz {
            access_log off;
            return 200 "ok\n";
            add_header Content-Type text/plain;
        }

        location / {
            proxy_pass http://backend-svc:80;
            proxy_connect_timeout 2s;
            proxy_read_timeout 5s;
            proxy_intercept_errors on;
            error_page 502 503 504 = @fallback;
        }

        location @fallback {
            add_header X-Degraded "true";
            return 200 "degraded: backend unavailable, serving fallback\n";
            add_header Content-Type text/plain;
        }
    }
YAML

# Step 2: update the Deployment to mount the config and use /healthz
kubectl -n dojo-chaos-dep apply -f - <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app
  namespace: dojo-chaos-dep
  labels:
    app: app
spec:
  replicas: 2
  selector:
    matchLabels:
      app: app
  template:
    metadata:
      labels:
        app: app
    spec:
      containers:
        - name: app
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
          readinessProbe:
            httpGet:
              path: /healthz
              port: 80
            initialDelaySeconds: 3
            periodSeconds: 5
            failureThreshold: 2
          livenessProbe:
            httpGet:
              path: /healthz
              port: 80
            initialDelaySeconds: 10
            periodSeconds: 10
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
            limits:
              cpu: 200m
              memory: 64Mi
          volumeMounts:
            - name: nginx-conf
              mountPath: /etc/nginx/conf.d
      volumes:
        - name: nginx-conf
          configMap:
            name: app-nginx-conf
YAML
```

## Why each piece is correct

**`proxy_connect_timeout 2s` / `proxy_read_timeout 5s`**: Without timeouts, nginx will wait up to 60 seconds for a backend that's gone, holding the client connection open. Short timeouts let nginx detect backend absence quickly and serve the fallback.

**`proxy_intercept_errors on` + `error_page 502 503 504 = @fallback`**: By default nginx passes backend error codes directly to the client. `proxy_intercept_errors on` tells nginx to handle those codes itself, enabling the `error_page` redirect to `@fallback`.

**`location @fallback`**: Named locations (`@name`) are internal — unreachable from outside the server. The `= /fallback` in `error_page` means "use this location's response as the complete response" (not a redirect). The `X-Degraded: true` header lets downstream monitoring detect degraded-mode responses and alert on elevated rates.

**`readinessProbe` on `/healthz` not `/`**: `/` is correct for the minimal fix (nginx always returns 200), but `/healthz` is clearer signal. More importantly, it does NOT proxy to the backend — it short-circuits at the `return 200` and never touches `backend-svc`. If you used `/` with a proxy_pass for everything, the readiness check would proxy to backend, recreating the original bug.

## Verify the fallback works

```bash
# Port-forward the app service and test the fallback manually
kubectl -n dojo-chaos-dep port-forward svc/app-svc 8080:80 &
kubectl -n dojo-chaos-dep scale deploy/backend --replicas=0
sleep 12   # wait for backend pods to terminate

curl -i http://localhost:8080/
# → HTTP/1.1 200 OK
# → X-Degraded: true
# → degraded: backend unavailable, serving fallback

curl -s http://localhost:8080/healthz
# → ok

kill %1   # stop port-forward
kubectl -n dojo-chaos-dep scale deploy/backend --replicas=2   # restore
```
