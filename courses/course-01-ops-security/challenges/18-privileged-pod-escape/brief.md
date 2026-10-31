# Escape the Box

A teammate needed "just a quick debug pod with access to the host" and shipped this into `dojo-escape`:

```yaml
securityContext:
  privileged: true
volumes:
  - name: host
    hostPath:
      path: /            # the entire node filesystem
```

They reasoned: *"It's still a container, the kernel namespaces isolate it."* They are wrong, and this challenge proves it. A privileged pod shares the host's capabilities and devices; a `hostPath: /` mount hands it the node's root filesystem directly. Together they are not isolation with a hole in it — they are **a root shell on the node wearing a pod costume.**

On the node that runs this pod there is a file readable only by the node's `root` user:

```
/root/flag.txt      (mode 0600, owner root)      →  KUBE{...}
```

You cannot read it from the API — it isn't a Secret, a ConfigMap, or an env var. It lives on the **node's disk**. Your job is to escape the container and read it the way an attacker who landed an RCE in a privileged pod would.

## The target

```
┌─────────────── kind node: dojo-worker (a docker container on your Mac) ───────────────┐
│                                                                                        │
│   /root/flag.txt  (0600, root)  ◀── you need THIS                                      │
│                                                                                        │
│   ┌──────── pod: escape-pod (namespace dojo-escape) ────────┐                          │
│   │  privileged: true                                       │                          │
│   │  volumeMount: hostPath / → /host                        │  ── two independent      │
│   │  you start here (a shell via kubectl exec)              │     escape paths out ─▶  │
│   └──────────────────────────────────────────────────────────┘                        │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

The pod is pinned to node **`dojo-worker`** with `nodeName`, and the flag is planted on that same node — so the host filesystem you reach *is* the one holding the flag. (If you forget which node, `kubectl -n dojo-escape get pod escape-pod -o wide` shows it.)

## Mission

Get a shell in `escape-pod`, reach the node filesystem, and read `/root/flag.txt`. There are at least **three** legitimate paths — find more than one, because each maps to a real-world breakout primitive:

1. **The hostPath mount** — the node's `/` is already sitting at `/host` inside the pod. The flag is one `cat` away.
2. **`chroot` / `nsenter` via privileged** — even without the mount, `privileged: true` gives you the capabilities and `/proc` access to pivot into the host's mount and PID namespaces.
3. **Writing into the node's filesystem** — because the mount is writable, you can drop a file into the host (e.g. a cron job or an SSH key) and own the node persistently, not just read one file.

Submit the flag you recover.

## Why this matters

| Thing you did | Real-world consequence |
|---------------|------------------------|
| Read `/root/flag.txt` | read any secret, kubelet cert, or service-account token on the node |
| Reached the node's `/var/lib/kubelet` | steal **every** pod's mounted secrets on that node, not just your own |
| Wrote into the host filesystem | plant a static pod in `/etc/kubernetes/manifests` → persistent root, survives pod deletion |
| Read the kubelet's `/etc/kubernetes/*.conf` | pivot to the API server; on a control-plane node, reach etcd → cluster-admin |

A privileged pod is a **node-level** compromise, and the node runs *other tenants'* pods. "It's just one debug pod" is how a single RCE becomes the whole cluster. There is **no `verify.sh`** here — the node filesystem is your evidence. The solution covers exactly how to make sure no workload can ever do this again.
