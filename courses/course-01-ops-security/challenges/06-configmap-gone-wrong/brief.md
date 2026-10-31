# ConfigMap Gone Wrong

A teammate shipped an nginx Deployment that's supposed to serve a custom landing page out of a ConfigMap. The pods are `Running`, the ConfigMap exists, the volume is mounted — every status is green — and yet hitting the service returns nginx's stock **403 Forbidden** instead of the page. Nobody touched the image; the problem is entirely in how the config is wired.

This is the quiet failure class of ConfigMaps: Kubernetes has **no idea** what your app expects a file to be named or where it expects to find it. A ConfigMap key becomes a *filename* when projected as a volume, and the `mountPath` decides *which directory* those files land in. Get either wrong and the object is perfectly valid — it just mounts the right content under the wrong name, or in the wrong place, and your app never sees it.

```
ConfigMap  web-content                 Pod: /usr/share/nginx/html/
┌───────────────────────────┐          ┌───────────────────────────┐
│ data:                     │          │  <key-name>   <-- filename │
│   <key> : "<file bytes>"  │ ──mount──▶│                            │
└───────────────────────────┘          └───────────────────────────┘
        ▲                                        ▲
   key name == the filename            mountPath == the directory
   nginx looks for index.html          nginx's docroot is here
```

nginx serves `/usr/share/nginx/html/index.html` for a request to `/`. If the projected file is named anything else (or lands anywhere else), nginx finds no `index.html` in its docroot, directory listing is off, and you get `403 Forbidden`.

## Mission

Fix the `web` Deployment / `web-content` ConfigMap in namespace `dojo-config` so that nginx serves the intended page. The page must contain the exact marker string:

```
DOJO_CONFIG_OK
```

You can fix this on either side of the wiring — rename the ConfigMap key so it projects as `index.html`, or adjust the `volumeMount` so the content lands where nginx looks. The content itself is already correct; only the **name/location** is wrong.

## Target state

The verifier accepts your work only when **both** of these are true in `dojo-config`:

1. A ConfigMap named `web-content` exists with a key **`index.html`** whose value contains the marker.
2. `kubectl -n dojo-config exec deploy/web -- wget -qO- localhost` returns a page containing **`DOJO_CONFIG_OK`**.

When you believe the page serves correctly, run the verifier. It inspects the ConfigMap and curls the running pod, printing the flag only if both checks pass.
