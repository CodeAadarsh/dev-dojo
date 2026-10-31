# Secrets & etcd Exfiltration

> **Module 04 · Course 03** — Module 01 drew the escalation chain and the first challenge walked the pod-to-cluster link. This module stops on the single object teams trust the most and understand the least: the Kubernetes **Secret**. You already store DB passwords and API keys in them at work. The uncomfortable truth is that a default Secret is protected by *access control, not cryptography* — and there are at least four distinct places an attacker (or an audit) can read it. We will read the same credential through every one of them, then close each door.

You run Kubernetes in production, so you know how to *create* a Secret. What separates an operator from a defender is knowing exactly where that Secret's plaintext is reachable: in the API response, in etcd on disk, in the pod's environment, in a mounted file, and in the token every pod silently carries. Each is a real exfiltration path with a real CVE-shaped history behind it, and each has one precise control that shuts it.

---

## The lie in "it's in a Secret, so it's encrypted"

A Kubernetes Secret is a first-class API object whose values are **base64-encoded**, not encrypted, unless you deliberately turned on encryption-at-rest. base64 is a *transport encoding* — it exists so arbitrary bytes survive a YAML/JSON round-trip, not to hide anything. Decoding needs no key, no password, nothing.

```bash
# "encryption" you can reverse with zero secrets of your own:
echo 'S1VCRXtiYXNlNjRfaXNfbm90X2VuY3J5cHRpb259' | base64 -d; echo
```

Hold the whole picture in your head before we touch a single command — the same value exists, in the clear, in five places:

```
                        one Secret: db-credentials.FLAG
                                     │
        ┌──────────────┬────────────┼─────────────┬───────────────┐
        ▼              ▼            ▼              ▼               ▼
  API response    etcd on disk   pod env var   mounted file    SA-token
  (.data base64)  (/registry/..) (envFrom)     (tmpfs volume)  reach to API
        │              │            │              │               │
   needs: RBAC    needs: node    needs: exec/   needs: exec/    needs: a
   get secret     access         crash dump     fs read         mounted token
        │              │            │              │               │
   CONTROL:       CONTROL:       CONTROL:       CONTROL:        CONTROL:
   least-priv     encryption-    mount-as-file  file perms +    automount=false
   RBAC           at-rest        not-env        readOnly        + tight RBAC
```

The rest of this module is that diagram, column by column, attack then defense.

---

## Path 1 — the API response (what `get secret` really hands back)

Anyone the API server authorizes for `get`/`list` on `secrets` in a namespace gets the plaintext, full stop. `-o yaml` shows you the base64; one pipe undoes it.

```bash
# the raw object — .data values are base64, NOT ciphertext
kubectl -n dojo-ctf get secret db-credentials -o yaml

# pull one field and decode it in a single line (you'll use this constantly)
kubectl -n dojo-ctf get secret db-credentials -o jsonpath='{.data.FLAG}' | base64 -d; echo

# dump every key decoded, no jq required, via go-template:
kubectl -n dojo-ctf get secret db-credentials -o go-template='
{{- range $k, $v := .data }}{{ $k }}={{ $v | base64decode }}{{ "\n" }}{{ end }}'
```

The point that lands in a security review: there is **no decryption step**. If `get secrets` is in a Role, the credential is in the clear to whoever holds that Role. This is why the single most valuable RBAC audit you can run is "who can read Secrets":

```bash
# every subject that can read Secrets cluster-wide — run this on prod, be surprised
kubectl get rolebindings,clusterrolebindings -A -o json \
  | kubectl get clusterrole,role -A -o name 2>/dev/null; \
kubectl auth can-i get secrets --all-namespaces \
  --as=system:serviceaccount:dojo-ctf:worker-sa
```

> **`list` is as dangerous as `get`.** Teams scope a Role to `get` thinking they've locked it to known names, then add `list` for a dashboard — and `list secrets` returns *every* Secret's `.data` in one call. There is no "list the names but not the values" verb for Secrets. If something needs to enumerate Secrets without reading them, it is almost always a design smell.

### Defense for Path 1 — RBAC that pins the resource

```yaml
# Least privilege: this SA may read exactly ONE Secret, by name, get only.
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: one-secret-reader
  namespace: dojo-ctf
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get"]                       # not list, not watch
    resourceNames: ["db-credentials"]    # not every Secret in the namespace
```

`resourceNames` is the lever most teams forget. Without it, `get secrets` means *all* Secrets. With it, a compromised token can fetch the one Secret the workload legitimately uses and nothing else. Verify the grant collapsed:

```bash
kubectl auth can-i get secret other-secret -n dojo-ctf \
  --as=system:serviceaccount:dojo-ctf:worker-sa          # -> no
```

---

## Path 2 — etcd on the node (bypassing RBAC entirely)

RBAC is enforced by the API server. If you can read etcd directly — because you have node access, a stolen etcd client cert, or an exposed `:2379` — you never talk to the API server, so **RBAC never runs**. Every object, including every Secret, is there. On your kind cluster, etcd is a static pod in the control-plane container, and "the node" is one `docker exec` away. That is the whole reason Module 01 kept repeating *node = container*.

First, confirm where etcd lives and which certs unlock it:

```bash
# etcd runs as a static pod; its client certs are on the control-plane node
docker exec dojo-control-plane ls /etc/kubernetes/pki/etcd/
# ca.crt  ca.key  healthcheck-client.crt  peer.crt  peer.key  server.crt  server.key
```

Now read a Secret straight out of the datastore. The object is stored as serialized protobuf; `strings` turns it back into something greppable:

```bash
docker exec dojo-control-plane sh -c '
  ETCDCTL_API=3 etcdctl \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    get /registry/secrets/dojo-ctf/db-credentials' | strings | grep -A2 FLAG
```

Read the key path like a filesystem: `/registry/<resource>/<namespace>/<name>`. You can list everything etcd holds the same way:

```bash
docker exec dojo-control-plane sh -c '
  ETCDCTL_API=3 etcdctl --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key \
    get /registry/secrets/ --prefix --keys-only' | head
```

> **The kill shot a defender must internalize:** on a cluster *without* encryption-at-rest, anyone who can read the etcd data directory — a backup file on an S3 bucket, a snapshot on a stolen disk, a misconfigured `:2379` — owns every credential in the cluster, and no RBAC policy you ever wrote applied. etcd backups are the most under-guarded copy of your entire secret store.

### Defense for Path 2 — encryption-at-rest

Turn Secrets into actual ciphertext on disk so a raw etcd read returns gibberish. You configure an `EncryptionConfiguration` and point the API server at it with `--encryption-provider-config`:

```yaml
# /etc/kubernetes/enc/encryption-config.yaml  (lives on the control-plane node)
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources: ["secrets"]
    providers:
      - aescbc:                      # or, far better, a kms: provider backed by a real KMS
          keys:
            - name: key1
              secret: <32-byte base64 key>   # from: head -c 32 /dev/urandom | base64
      - identity: {}                 # fallback so existing plaintext objects still read
```

After enabling it and re-writing existing Secrets (`kubectl get secrets -A -o json | kubectl replace -f -`), the same etcd read now shows the encryption envelope instead of the flag:

```bash
docker exec dojo-control-plane sh -c '... etcdctl get /registry/secrets/dojo-ctf/db-credentials' | strings | head
# -> k8s:enc:aescbc:v1:key1:<ciphertext>     (no plaintext, no FLAG)
```

The `k8s:enc:aescbc:v1:key1:` prefix is how you *prove* encryption-at-rest is actually on — that's your audit check. Note the ordering of providers: list your encrypting provider **first** (it's used to write) and `identity` **last** (so pre-existing plaintext still decodes until you rewrite it). In production, prefer a `kms` provider over a static `aescbc` key so the key-encryption-key lives in a real HSM/KMS and never sits next to the data it protects.

---

## Path 3 — the pod environment (envFrom leakage)

Mounting a Secret as environment variables (`envFrom.secretRef` or `env.valueFrom.secretKeyRef`) puts the plaintext into the process environment of *every* process in the container — and environments leak in ways files don't.

```bash
# read the whole environment of a running workload
kubectl -n dojo-ctf exec deploy/billing -- env | grep -E 'FLAG|PASSWORD'

# even without exec, a crash dump or an error page often prints os.environ:
#   Python tracebacks, Node unhandledRejection logs, Java -Dprint, Go panic dumps
```

Why env is strictly weaker than a file:

| Leakage vector | env var | mounted file |
|----------------|---------|--------------|
| Visible to every subprocess (inherited) | yes | no |
| `/proc/<pid>/environ` readable by same-uid procs | yes | no |
| Dumped by crash handlers / APM / error pages | commonly | rarely |
| Shows up in `kubectl describe pod` | key refs only | no |
| Rotatable without a pod restart | no | yes (kubelet refreshes the file) |

That last row matters operationally too: a Secret mounted as a file is updated in place by the kubelet when the Secret changes, so rotation needs no restart. An env var is baked in at container start — rotating the Secret does nothing until you redeploy.

### Defense for Path 3 — mount as a file, read-only

```yaml
spec:
  containers:
    - name: app
      image: busybox:1.36
      volumeMounts:
        - name: creds
          mountPath: /etc/creds
          readOnly: true
  volumes:
    - name: creds
      secret:
        secretName: db-credentials
        defaultMode: 0400          # owner-read-only; not world/group readable
```

The app reads `/etc/creds/FLAG`. It is not in the environment, not inherited by subprocesses, not in `/proc/<pid>/environ`, and `0400` keeps it off-limits to other UIDs. It is the single cheapest hardening on this page.

---

## Path 4 — the mounted ServiceAccount token (the credential you forgot you issued)

Every pod, by default, mounts a ServiceAccount token at `/var/run/secrets/kubernetes.io/serviceaccount/token`. That token *is* a Secret — a bearer credential to the API server — and Challenge 01 already proved a pod can use it to read other Secrets if its SA has the RBAC. The token is itself the thing an attacker exfiltrates first, because it is on disk in *every* pod with no further access needed.

```bash
# from inside any pod — the three files that make you an API client
SA=/var/run/secrets/kubernetes.io/serviceaccount
cat "$SA/token"      # signed JWT = who you are to the API server
cat "$SA/ca.crt"     # trust the API server's TLS
cat "$SA/namespace"  # where you are
```

### Defense for Path 4 — don't issue the credential at all

```yaml
# ServiceAccount or pod spec: no mount means no token to steal
automountServiceAccountToken: false
```

If a workload never calls the API server — most don't — it has no business carrying an API credential. Setting `automountServiceAccountToken: false` on the SA (or per-pod) removes the file entirely. Combined with least-privilege RBAC (Path 1), a compromised app has nothing to present and nothing to escalate with.

---

## Debugging Secret exposure

When you are auditing (or responding to) Secret leakage, work this table top-to-bottom — the cheapest, most common exposure first, and the node-level one last because it's the hardest to pull off and the most catastrophic.

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| A low-privilege SA can read a Secret it shouldn't | `get`/`list secrets` granted via a Role/ClusterRole with no `resourceNames` | Pin the Role with `resourceNames`; drop `list`; re-run `auth can-i` to confirm `no` |
| Secret value appears in app logs / error pages / APM | Secret mounted as env var, printed by a crash handler | Switch to a file mount with `defaultMode: 0400`; scrub the log sink |
| `etcdctl get /registry/secrets/...` returns readable plaintext | Encryption-at-rest not enabled | Add `EncryptionConfiguration` (aescbc/kms), rewrite all Secrets, verify the `k8s:enc:` prefix |
| An etcd snapshot/backup leaks every credential | Backups taken before encryption, or key stored beside the data | Encrypt at rest with a **kms** provider; encrypt backups; rotate every exposed credential |
| Pod carries a token it never uses | `automountServiceAccountToken` left at default `true` | Set it `false` on the SA/pod; the token file disappears |
| Can't tell if encryption-at-rest is actually on | No one checked the on-disk form | Do the etcd read below and look for `k8s:enc:` vs a plaintext object |

### Diagnose each — the exact commands

**Is this Secret readable by a given SA?** Impersonate it; don't guess:

```bash
kubectl auth can-i get secret db-credentials -n dojo-ctf \
  --as=system:serviceaccount:dojo-ctf:worker-sa
kubectl auth can-i list secrets -n dojo-ctf \
  --as=system:serviceaccount:dojo-ctf:worker-sa     # list is the scarier one
```

**Which Roles grant Secret access at all?** Find the bindings, then read the rules:

```bash
kubectl get clusterrolebinding,rolebinding -A -o wide \
  | grep -iE 'secret|admin|edit'
kubectl get clusterrole edit -o jsonpath='{range .rules[*]}{.resources}{" -> "}{.verbs}{"\n"}{end}' \
  | grep -i secret                                  # the built-in 'edit' role CAN read Secrets
```

**Is encryption-at-rest genuinely on?** The only honest test is reading the bytes etcd stored:

```bash
docker exec dojo-control-plane sh -c '
  ETCDCTL_API=3 etcdctl --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key \
    get /registry/secrets/dojo-ctf/db-credentials' | strings | head
# plaintext object  -> NOT encrypted
# k8s:enc:aescbc... -> encrypted at rest
```

**`etcdctl: not found` inside the node container?** The node image doesn't always ship it on `PATH`; the etcd *static pod* always does. Go through the pod instead:

```bash
kubectl -n kube-system get pod -l component=etcd -o name
kubectl -n kube-system exec etcd-dojo-control-plane -- sh -c '
  ETCDCTL_API=3 etcdctl --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key \
    get /registry/secrets/dojo-ctf/db-credentials' | strings | grep FLAG
```

> **War story.** On the LGTM log pipeline at SAP we rotated a Loki object-storage credential by updating the Secret, confirmed the new value with `kubectl get secret -o jsonpath`, and declared it done. Ingestion kept authenticating with the **old** key for another nine hours until the pods happened to roll. The cause was exactly Path 3: the credential was wired in as an `envFrom` env var, which is frozen at container start — the live Secret had changed but the running processes still held the stale environment. We moved it to a projected file mount (which the kubelet refreshes in place) and added a check to the rotation runbook: after rotating, read the value *from inside a running pod* (`kubectl exec -- cat /etc/creds/...`), not from the API object, because the API object will lie to you about what the workload is actually using. Env-mounted secrets don't just leak more easily — they rotate worse.

---

## Checkpoint

You're ready to move on when you can, without looking anything up:

1. Explain in one sentence why base64 is not encryption, and decode a `.data` value in a single piped command.
2. Name all five places the same Secret's plaintext is reachable, and the one control that closes each.
3. Read a Secret straight out of etcd on the kind control-plane node with `etcdctl`, and say why RBAC did not apply.
4. Recognize the `k8s:enc:aescbc:v1:` prefix and use it to prove encryption-at-rest is on — then say why `identity` must be the last provider and a `kms` provider beats a static key.
5. State why `list secrets` is more dangerous than `get secrets`, and why `resourceNames` is the lever most teams forget.
6. Explain why mounting a Secret as a file beats env vars on four axes — leakage, crash dumps, `/proc`, and rotation.
7. Fall back from a missing `etcdctl` in the node container to the etcd static pod, and know the key path shape `/registry/<resource>/<ns>/<name>`.
8. Say what `automountServiceAccountToken: false` removes and why a workload that never calls the API should never carry a token.

➡ Next up: **Module 05 — Container Escapes & Node Compromise.** Everything so far assumed the attacker stayed inside a pod. Next we break that boundary: a `privileged` container, a `hostPath` of `/`, and a `chroot` onto the host — then the Pod Security Admission policy that makes all of it impossible.
