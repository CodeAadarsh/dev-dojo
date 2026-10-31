# Solution — ConfigMap Gone Wrong

The content was never the problem — the **filename** was. The ConfigMap stored the page under the key `home.html`, so the volume projected `/usr/share/nginx/html/home.html`. nginx serves `index.html` from its docroot and, finding none, returns `403 Forbidden`.

There are two correct fixes. Either makes the verifier pass; the first is the one the verifier's ConfigMap check expects.

## Fix A — rename the key to `index.html` (recommended)

The key *is* the filename. Rename it and the file lands as `index.html`.

```yaml
# web-content.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: web-content
  namespace: dojo-config
data:
  index.html: |                 # was: home.html
    <!doctype html>
    <html>
      <head><title>Dojo Config</title></head>
      <body>
        <h1>Served from a ConfigMap</h1>
        <p>DOJO_CONFIG_OK</p>
      </body>
    </html>
```

```bash
kubectl apply -f web-content.yaml
# nginx reads the file on request, but to be safe force a fresh pod:
kubectl -n dojo-config rollout restart deploy/web
kubectl -n dojo-config rollout status deploy/web
bash courses/course-01-ops-security/challenges/06-configmap-gone-wrong/verify.sh
```

## Fix B — remap the key with `items` (keep the key name)

If you can't rename the key, project *just that key* to the filename nginx wants using `items.path`:

```yaml
      volumes:
        - name: content
          configMap:
            name: web-content
            items:
              - key: home.html      # the key as stored
                path: index.html    # the filename it mounts as
```

`items` gives you per-key control of the projected filename and is the clean way to mount a single key without dragging in every other key in the ConfigMap. (A third option — `subPath` on the `volumeMount` — also works but freezes the file: `subPath` mounts do **not** receive live ConfigMap updates, which is a surprise you don't want.)

## Why the pod looked healthy the whole time

Nothing here is an *error* to Kubernetes. The ConfigMap is valid, the volume mounts, the container starts, probes (if any) against `/` would even… well, get a 403, which is still an HTTP response. The pod is `Running` and, with no readiness probe checking body content, `Ready`. The breakage lives entirely at the application contract — "the file is named `index.html` and sits in the docroot" — which Kubernetes neither knows nor enforces.

## Debugging move worth keeping

When a config-from-ConfigMap mount misbehaves, look at what actually landed in the container rather than guessing from the YAML:

```bash
kubectl -n dojo-config exec deploy/web -- ls -l /usr/share/nginx/html
# home.html  <-- there's your smoking gun: wrong filename, no index.html
kubectl -n dojo-config exec deploy/web -- wget -qO- localhost   # 403 before the fix
```

The directory listing is the fastest way to catch a key/mountPath mismatch — the file is right there under the wrong name.
