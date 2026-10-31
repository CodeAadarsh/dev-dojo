# Wire It Up

CKAD lives and dies on wiring config into workloads quickly and the *right* way: non-secret config as **environment variables**, secrets as **mounted files**. This drill is exactly that.

## Mission

In namespace `dojo-wire` (created by setup), create:

1. a **ConfigMap** named `app-config` with a couple of keys (e.g. `APP_MODE=prod`, `LOG_LEVEL=info`)
2. a **Secret** named `app-secret` with a key (e.g. `api-key=s3cr3t`)
3. a **Deployment** named `app` (`nginx:1.27-alpine`) that:
   - consumes the **whole** ConfigMap as env with **`envFrom`**
   - **mounts** the Secret as a **volume** (e.g. at `/etc/secret`)

The Deployment must have **≥1 Ready replica**.

## Why the env-vs-file split

ConfigMap-as-env is convenient for plain config. Secrets mounted as **files** are safer than secrets as env: file mounts can be `tmpfs`, aren't inherited by child processes, don't leak into `kubectl describe`/crash dumps, and update when the Secret changes (env is a one-time snapshot). The exam — and good practice — rewards this distinction.

Run the verifier once `app` is Ready.
