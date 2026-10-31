# Config & Secrets Done Right

> **Module 05 · Course 01** — Configuration is where "works on my cluster" goes to die. Hardcode it and you can't promote an image across environments; mishandle it and you leak credentials into logs, crash dumps, and etcd. This module is about injecting config and secrets *correctly* — which mount type, which immutability guarantee, and the hard truth that a Kubernetes Secret is not encrypted until you make it so.

You already use ConfigMaps and Secrets at work. The goal here is the parts that separate competent from expert: why file mounts beat env vars, what immutability buys you at scale, and the full chain from `base64` to real encryption at rest with EncryptionConfiguration and KMS.

---

## ConfigMap: four ways in, and they are not equal

A ConfigMap is just a map of key→value (string data), decoupling config from the image so the *same* image runs in dev, staging, and prod. There are four injection styles, and choosing wrong is a real bug source.

| Style | Spec shape | Live reload? | Use it for |
|-------|-----------|--------------|-----------|
| Single env var | `env[].valueFrom.configMapKeyRef` | No | A handful of individual values |
| Bulk env | `envFrom.configMapRef` | No | "Import all keys as env vars" |
| File/volume mount | `volumes[].configMap` → `volumeMounts` | **Yes** | Config files, anything that can change |
| Projected volume | `volumes[].projected` | **Yes** | Combining CM + Secret + token into one dir |

```yaml
# all four, side by side
spec:
  containers:
    - name: app
      image: nginx:1.27-alpine
      env:
        - name: LOG_LEVEL                       # (1) single key
          valueFrom:
            configMapKeyRef: { name: app-cm, key: LOG_LEVEL }
      envFrom:
        - configMapRef: { name: app-cm }        # (2) every key as an env var
      volumeMounts:
        - name: cfg                             # (3) files under /etc/app
          mountPath: /etc/app
  volumes:
    - name: cfg
      configMap:
        name: app-cm
```

The reload asymmetry is the thing to burn in: **env vars are snapshotted at container start and never change.** Update the ConfigMap and the running process keeps the old value until the pod is recreated. **Volume-mounted** ConfigMaps, by contrast, are updated in place by the kubelet (eventually — up to ~1 minute, longer with the cache), so a process that re-reads the file sees the new value without a restart.

> **Projected volumes** let you assemble several sources — a ConfigMap, a Secret, and a `serviceAccountToken` — into a single directory with chosen paths. That's how you hand an app one tidy `/etc/app` tree instead of scattering mounts, and it's the modern way to get a bound, auto-rotating SA token instead of the legacy static one.

Two edge-cases that bite even experienced operators:

- **`subPath` mounts are frozen.** The live-reload guarantee only holds for a whole-volume mount. The moment you use `volumeMounts[].subPath` to drop a single file next to existing files (e.g. mount just `nginx.conf` into `/etc/nginx/`), the kubelet resolves it **once at start** and never updates it again — it behaves like an env var for reload purposes. If you need both "one file in a shared dir" *and* live reload, mount the whole ConfigMap to a side directory and symlink, or accept a restart.
- **Missing key / missing ConfigMap fails the pod.** A `configMapKeyRef` or `configMapRef` is **required by default** — if the ConfigMap or the key doesn't exist, the pod stays `CreateContainerConfigError` and never starts. Set `optional: true` on the ref when a value is genuinely optional, otherwise a typo'd key name is a hard stop, not a warning.

---

## Secret: same shape, different type, same (weak) default

A Secret is structurally a ConfigMap whose values are base64 in the API and the kubelet tries to keep off disk (tmpfs-backed when mounted). The `type` field tells Kubernetes how to validate and use it:

| Secret type | Holds | Consumed by |
|-------------|-------|-------------|
| `Opaque` | Arbitrary key/values (the default) | Your app |
| `kubernetes.io/dockerconfigjson` | Registry creds | `imagePullSecrets` |
| `kubernetes.io/tls` | `tls.crt` + `tls.key` | Ingress, webhooks |
| `kubernetes.io/service-account-token` | SA token | Legacy SA auth |
| `kubernetes.io/basic-auth`, `ssh-auth` | Structured creds | Tools expecting those keys |

Using the right type matters: an Ingress TLS block expects a `kubernetes.io/tls` Secret with exactly `tls.crt`/`tls.key`, and `imagePullSecrets` expects `dockerconfigjson`. Wrong type → silent non-use.

> **The default you must internalize:** the value under `.data` is **base64-encoded, not encrypted.** `base64 -d` needs no key. This is the entire point of the **"base64 Is Not Encryption"** discovery challenge in this course — you extracted `KUBE{base64_is_not_encryption}` three different ways (decode the Secret, read it from the pod's env, read it from etcd). Everything below is how you make that attack *not* trivial.

The one authoring gotcha that produces the most "my password is wrong" tickets: **`data` vs `stringData`.** `data` values must already be base64; `stringData` values are plaintext that the API server base64-encodes for you on write. If you hand-encode with `echo "s3cret" | base64`, you just baked a **trailing newline** into the credential (`czNjcmV0Cg==` decodes to `s3cret\n`) and the app's auth fails with a value that *looks* identical to the eye. Use `printf '%s'` or `echo -n`, or just use `stringData` and let Kubernetes encode it.

---

## env vs file mounts — why files are safer

You can mount a Secret as environment variables or as files. For anything sensitive, **mount as files.** The reasons are concrete, not stylistic:

```
   Secret as ENV                    Secret as FILE (volume)
   ─────────────                    ───────────────────────
 • readable via `exec … env`      • tmpfs, not on node disk
 • inherited by child procs       • not inherited by children
 • leaks into crash dumps/core    • not in process environment
 • shows in some logging/APM       • fine-grained file mode (0400)
 • frozen at start, no rotation    • updates in place → rotatable
```

- **Child-process inheritance.** Every subprocess your app spawns inherits the full environment — including the DB password. A shell-out to a misbehaving tool now has your credential. File mounts don't leak this way.
- **Observability leakage.** APM agents, crash handlers, and `/proc/<pid>/environ` all expose env. Your own 100GB/day logging pipeline is exactly the kind of place a secret in an env var ends up permanently indexed. A file at `/etc/secrets/db-password` doesn't get captured by a stack-trace dumper.
- **Rotation.** As in the ConfigMap case, env is frozen at container start; a mounted Secret file updates in place, so an external rotator can swap the credential and a re-reading app picks it up without a restart.

```yaml
      volumeMounts:
        - name: db
          mountPath: /etc/secrets
          readOnly: true
  volumes:
    - name: db
      secret:
        secretName: db-creds
        defaultMode: 0400          # owner read-only
```

> This is the direct hardening of challenge path 2, where `kubectl exec deploy/billing -- env | grep FLAG` dumped the plaintext. Mounted as a `0400` file, it's no longer sitting in the environment for any `exec`, child process, or crash dumper to scoop up.

One more trap hiding in that `defaultMode`: it's interpreted as **octal**, but if you write it in JSON/patch as a decimal (`420` is the decimal for octal `0644`) you'll confuse yourself reading it back. And `defaultMode` is silently ignored on Windows nodes and when `fsGroup`/`runAsNonRoot` interactions force a different owner — always confirm with `kubectl exec -- stat -c '%a %U' /etc/secrets/db-password` rather than trusting the manifest.

---

## Immutable ConfigMaps and Secrets

Set `immutable: true` and the object's `data` can never be changed — you must delete and recreate it to roll config. Counterintuitively, you *want* this for anything versioned:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-cm-v3
data:
  LOG_LEVEL: info
immutable: true
```

Two payoffs:

- **Performance at scale.** The kubelet **watches** every mounted ConfigMap/Secret for changes. Mark it immutable and the kubelet stops watching it — on a cluster with thousands of pods mounting config, that's a real reduction in API-server watch load and a known control-plane scaling win.
- **Safety.** An immutable object can't be edited out from under a running fleet by a fat-fingered `kubectl edit`. You roll config the GitOps way: create `app-cm-v3`, update the Deployment to reference it (which triggers a normal rolling update), retire `v2`. The config version is pinned to the pod template, so a rollback of the Deployment rolls back the config too.

> The name-versioning pattern (`-v2`, `-v3`, or a content hash suffix) pairs with immutability: changing the referenced name is what makes the Deployment notice and roll. Kustomize's `configMapGenerator` does this automatically by appending a content hash.

The sharp edge: once `immutable: true` is set, you cannot *unset* it either — the `immutable` field is itself immutable. Trying to `kubectl apply` a changed `data` block onto an immutable object fails with `field is immutable`; `kubectl edit` silently rejects the save. The only path forward is `kubectl delete && kubectl apply` (or the versioned-name roll above), which means a plain `apply` in a CI pipeline will hard-fail on an immutable object it expected to update — a surprise the first time it happens in prod.

---

## Encryption at rest: making Secrets actually secret

By default Secrets are written to etcd as base64 — anyone with etcd access (a node breakout, an etcd backup, a snapshot in a bucket) reads them in clear. **EncryptionConfiguration** on the API server fixes this: the apiserver encrypts resources *before* writing to etcd and decrypts on read.

You pass the apiserver `--encryption-provider-config` pointing at:

```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources: ["secrets"]
    providers:
      - kms:                       # best: key lives in a KMS (AWS/GCP/Vault), not on disk
          apiVersion: v2
          name: myKmsPlugin
          endpoint: unix:///var/run/kms/socket.sock
      - aescbc:                    # fallback: key material in the config file itself
          keys:
            - name: key1
              secret: <base64-32-byte-key>
      - identity: {}               # plaintext — keep LAST so reads of old data still work
```

The subtleties that matter:

- **Provider order = behavior.** The **first** provider encrypts writes; **all** listed providers are tried on read. Putting `identity: {}` last lets you read pre-existing plaintext Secrets while new writes get encrypted. Putting `identity` *first* silently disables encryption.
- **It's not retroactive.** Existing Secrets stay in their old form until rewritten. After enabling, force a rewrite:
  ```bash
  kubectl get secrets -A -o json | kubectl replace -f -
  ```
- **aescbc vs KMS.** `aescbc` keeps the key in the config file on the control-plane disk — better than nothing, but the key sits next to the data. **KMS v2** keeps the key in an external KMS and only ever has a short-lived data-encryption key in memory; this is the real-world target (and what managed control planes like EKS/GKE wire up for you).

> **Attacker's view, closed.** This is the fix for challenge path 3 (`etcdctl get /registry/secrets/...` returned the plaintext flag). With EncryptionConfiguration active, that same etcd read returns ciphertext — the node-breakout and stolen-backup paths go dark. RBAC (never grant `get secret` broadly) closes path 1; file mounts close path 2; encryption at rest closes path 3.

---

## Beyond native Secrets: External Secrets Operator, Vault, reloaders

The strongest posture is for the plaintext to **never live in a Kubernetes Secret at all** — keep it in a purpose-built secrets manager and sync on demand.

- **External Secrets Operator (ESO).** You write a non-sensitive `ExternalSecret` CR that *references* a key in AWS Secrets Manager / GCP Secret Manager / Vault / Azure Key Vault. ESO fetches the value and materializes a normal Secret, refreshing on an interval. Your Git repo holds only the reference, never the credential — which means GitOps (next module, ArgoCD) stays clean.
- **HashiCorp Vault.** Either the Vault Agent sidecar injects secrets as files into the pod, or the CSI Secrets Store driver mounts them as a volume. Both support **dynamic secrets** — short-lived DB credentials minted per-pod and revoked on exit — so there's no long-lived password to steal.

The remaining problem: when a secret rotates, a pod holding an **env** copy is stale until restarted. Two answers:

- **File mounts auto-update** (the kubelet refreshes the volume), so a process that re-reads the file picks up the rotation with no restart — another reason to prefer files.
- **Reloader** (e.g. `stakater/reloader`) watches the ConfigMaps/Secrets a Deployment references and triggers a **rolling restart** when they change — the pragmatic way to propagate config to apps that only read env/config at startup, without hand-editing the pod template.

```yaml
metadata:
  annotations:
    reloader.stakater.com/auto: "true"   # restart this Deployment when its CM/Secret changes
```

> **Decision rule:** native Secret + encryption at rest + file mounts is the solid baseline. Reach for ESO/Vault when you want the source of truth outside the cluster, dynamic/short-lived credentials, or a single secrets store across many clusters. Add Reloader whenever apps can't hot-reload and you refuse to restart pods by hand.

---

## Debugging config & secrets

Config bugs rarely throw a clean error — they present as "the app is using the wrong value" or "the pod won't start" with no stack trace pointing at Kubernetes. The table below maps the symptoms you'll actually see to their cause and the one command that confirms it.

| Symptom | Likely cause | Confirm / fix |
|---------|-------------|---------------|
| Changed the ConfigMap, app still uses old value | Value injected as **env var** → snapshotted at start | `kubectl exec POD -- env \| grep KEY` shows old value; roll the pods (`kubectl rollout restart`) or switch to a file mount |
| Changed a file-mounted ConfigMap, file still stale after >2 min | Mounted via `subPath` (frozen) **or** app caches the file in memory | `kubectl exec POD -- stat /etc/app/cfg` → mtime not advancing = subPath; drop subPath or restart |
| Pod stuck `CreateContainerConfigError` | Referenced ConfigMap/Secret or key doesn't exist and ref isn't `optional` | `kubectl describe pod POD` → event names the missing object; create it or set `optional: true` |
| Decoded secret value fails auth but "looks right" | Trailing `\n` from `echo` baked into base64, or wrong key decoded | `kubectl get secret S -o jsonpath='{.data.K}' \| base64 -d \| xxd \| tail` — look for a `0a` byte at the end |
| Two mounts, one directory, files missing | **Mount path collision** — a later `volumeMounts` entry shadows an earlier one on the same `mountPath` | `kubectl exec POD -- ls -la /mnt` vs the manifest; give each source a distinct path or use a projected volume |
| `kubectl apply` fails with `field is immutable` | Trying to update an `immutable: true` object | Roll via a new versioned name, or `kubectl delete && apply` |
| Secret file present but unreadable by the app | `defaultMode`/`fsGroup`/`runAsUser` mismatch — file owned by root, app runs as non-root | `kubectl exec POD -- stat -c '%a %U %G' /etc/secrets/f`; set `defaultMode` + `fsGroup` to match |

The core diagnostic loop, in order:

```bash
# 1. What is actually in the object (not what Git says)?
kubectl -n dojo-config get configmap app-cm -o yaml
kubectl -n dojo-config get secret db-creds -o jsonpath='{.data}' \
  | tr ',' '\n'                       # keys present without decoding plaintext

# 2. What did the CONTAINER actually receive? (ground truth, beats the manifest)
kubectl -n dojo-config exec deploy/app -- env | sort        # env snapshot
kubectl -n dojo-config exec deploy/app -- ls -la /etc/app   # mounted files
kubectl -n dojo-config exec deploy/app -- cat /etc/app/config.yaml

# 3. Why won't the pod start / mount?  Events carry the real reason.
kubectl -n dojo-config describe pod <pod>   # look at the Events block at the bottom

# 4. Prove a decode mistake — the byte-level view never lies
kubectl -n dojo-config get secret db-creds -o jsonpath='{.data.PASSWORD}' \
  | base64 -d | xxd | tail -2         # a trailing 0a == stray newline in the secret
```

For the "is the kubelet even refreshing this volume?" question, remember the refresh is driven by the kubelet's sync loop and the ConfigMap/Secret cache TTL (`configMapAndSecretChangeDetectionStrategy`, default `Watch`). If a file mount genuinely won't update, confirm the object changed in the API first (`kubectl get -o jsonpath='{.metadata.resourceVersion}'` before/after), then check you're not on a `subPath` or immutable mount — those two account for nearly every "live reload doesn't work" report.

> **War story.** On the LGTM log pipeline we rotated a downstream object-store credential by updating the Secret in place — and watched 40% of the ingest fleet keep authenticating with the *old* key for the rest of the day, backing up the write-ahead buffers until disks alarmed. The Secret was mounted as **env vars** via `envFrom`, so every running pod held a frozen copy from its start time; the new value sat in etcd, correct and ignored. Nothing errored in Kubernetes — `kubectl get secret` showed the new value, so it *looked* done. The fix was a `kubectl rollout restart` across the fleet, and the permanent fix was moving the credential to a **file mount** plus a `reloader.stakater.com/auto` annotation so a rotation triggers a controlled rolling restart automatically. Lesson burned in: "the Secret is updated" and "the running process sees the new Secret" are two different claims, and only one of them pages you at 2am.

---

## Checkpoint

You're ready to move on when you can, without looking anything up:

1. Name the four ConfigMap injection styles and state which two reflect updates without a pod restart.
2. Give three concrete reasons a file-mounted Secret is safer than the same value in an env var.
3. Explain what `immutable: true` buys you — both the control-plane scaling win and the safety win — and how you roll config when it's set.
4. Explain why a default Kubernetes Secret is *not* encrypted, and what EncryptionConfiguration changes about the bytes in etcd.
5. State why provider order in EncryptionConfiguration matters, and why enabling it doesn't protect existing Secrets until you rewrite them.
6. Say when you'd reach past native Secrets to ESO or Vault, and what Reloader solves that file mounts don't.
7. Explain why a `subPath` mount breaks the live-reload guarantee, and how you'd confirm it from inside the container.
8. Diagnose a pod stuck in `CreateContainerConfigError` and name the two refs that cause it when a key is missing.
9. Spot the trailing-newline secret bug and show the one command that proves it at the byte level.

➡ Next up: **GitOps with ArgoCD** — where all of this config, declared in Git and reconciled continuously, becomes the single source of truth for the cluster.
