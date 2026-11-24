# CIS Hardening and Incident Response — Locking Down and Fighting Back

> **Module 11 · Course 38** — Policies block known attacks. Falco detects unknown behavior. But what about everything that slipped through before you deployed those controls? And what about the cluster configuration itself — the API server flags, the etcd settings, the audit log policy that nobody turned on? This module covers CIS Kubernetes Benchmarks (the gold standard for cluster hardening) and the full Incident Response playbook for when something has already gone wrong.

---

## CIS Kubernetes Benchmark

The Center for Internet Security (CIS) publishes a detailed security benchmark for Kubernetes. It's a 200+ page document with specific, testable controls. Each control has:
- A test to run
- The expected result
- A remediation if it fails

### kube-bench — Automated CIS Scanning

```bash
# Run kube-bench as a Kubernetes Job
kubectl apply -f https://raw.githubusercontent.com/aquasecurity/kube-bench/main/job.yaml

# Wait for it to complete
kubectl wait --for=condition=complete job/kube-bench --timeout=120s

# Read the output
kubectl logs job/kube-bench 2>/dev/null
```

Output looks like:

```
[INFO] 1 Control Plane Security Configuration
[INFO] 1.1 Control Plane Node Configuration Files
[PASS] 1.1.1 Ensure that the API server pod specification file permissions are set to 600 or more restrictive
[FAIL] 1.1.11 Ensure that the etcd data directory permissions are set to 700 or more restrictive
  Remediation: Run the below command... chmod 700 /var/lib/etcd

[INFO] 1.2 API Server
[PASS] 1.2.1 Ensure that the --anonymous-auth argument is set to false
[FAIL] 1.2.6 Ensure that the --authorization-mode argument includes Node
  Remediation: Edit the API server pod specification file...

[WARN] 1.3.1 Ensure that the --terminated-pod-gc-threshold argument is set appropriately
  Remediation: Edit the Controller Manager pod specification file...

== Summary ==
27 checks PASS
5 checks FAIL
7 checks WARN
```

---

## Key CIS Level 1 Controls

Level 1 controls are the minimum viable security baseline. These are achievable, don't break existing workloads, and provide significant security improvement.

### API Server Controls

```bash
# 1.2.1: No anonymous auth (MUST be false)
# kube-apiserver flag: --anonymous-auth=false
# Prevents unauthenticated API calls to the apiserver

# 1.2.4: No insecure port
# kube-apiserver flag: --insecure-port=0
# Disables HTTP (non-TLS) API server port (default 8080)

# 1.2.6: Authorization mode must include Node and RBAC
# kube-apiserver flag: --authorization-mode=Node,RBAC
# Node authorization restricts kubelet's API access to its own node

# 1.2.9: Admission plugins must include EventRateLimit
# kube-apiserver flag: --enable-admission-plugins=...,EventRateLimit,...
# Prevents API server DoS via event flooding

# 1.2.22: Audit logging must be enabled
# kube-apiserver flags:
#   --audit-log-path=/var/log/apiserver/audit.log
#   --audit-policy-file=/etc/kubernetes/audit-policy.yaml
#   --audit-log-maxage=30
#   --audit-log-maxbackup=10
#   --audit-log-maxsize=100
```

### etcd Controls

```bash
# 2.1: etcd must have TLS peer and client auth
# etcd flags: --cert-file, --key-file, --client-cert-auth=true

# 2.2: etcd must not be publicly reachable
# etcd flag: --listen-client-urls=https://127.0.0.1:2379 (not 0.0.0.0)

# Check etcd encryption at rest:
# kube-apiserver flag: --encryption-provider-config=/etc/kubernetes/encryption.yaml
# encryption.yaml example:
cat << 'EOF'
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
- resources: [secrets]
  providers:
  - aescbc:
      keys:
      - name: key1
        secret: <base64-encoded-32-byte-key>
  - identity: {}  # fallback for existing unencrypted secrets
EOF
```

### Node Controls

```bash
# 4.1.1-4.1.6: kubelet config file permissions and ownership
# Should be owned by root:root, permissions 600

# 4.2.1: Anonymous auth disabled in kubelet
# kubelet config: authentication.anonymous.enabled: false

# 4.2.2: Kubelet authorization mode must be Webhook
# kubelet config: authorization.mode: Webhook
# (not AlwaysAllow — that lets any authenticated user call any kubelet endpoint)

# 4.2.6: Don't allow kernel version being read by containers
# kubelet config: allowedUnsafeSysctls: []
```

---

## Kubernetes Audit Logging — Full Setup

Audit logging is the most critical forensic tool. Without it, you're flying blind during an incident.

### Audit Policy File

```yaml
# /etc/kubernetes/audit-policy.yaml
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
# Log all secret reads at RequestResponse level (you need the payload)
- level: RequestResponse
  verbs: [get, list, watch]
  resources:
  - group: ""
    resources: [secrets, configmaps]

# Log pod exec at Metadata level (the command is in the URI, not the body)
- level: Metadata
  verbs: [create]
  resources:
  - group: ""
    resources: [pods/exec, pods/attach, pods/portforward]

# Log RBAC changes (someone added themselves to cluster-admin)
- level: RequestResponse
  verbs: [create, update, patch, delete]
  resources:
  - group: "rbac.authorization.k8s.io"
    resources: [clusterrolebindings, rolebindings, clusterroles, roles]

# Log authentication failures
- level: Metadata
  users: ["system:anonymous"]

# Log everything at Metadata level as a catch-all (but not the response body — too noisy)
- level: Metadata
  omitStages: [RequestReceived]
```

### Reading Audit Logs During Incident Response

A real audit log entry for `kubectl exec`:

```json
{
  "kind": "Event",
  "apiVersion": "audit.k8s.io/v1",
  "level": "Metadata",
  "auditID": "abc123...",
  "stage": "ResponseComplete",
  "requestURI": "/api/v1/namespaces/prod/pods/payment-pod/exec?command=sh&stdin=true&stdout=true&tty=true",
  "verb": "create",
  "user": {
    "username": "system:serviceaccount:dojo-poc:default",
    "groups": ["system:serviceaccounts", "system:authenticated"]
  },
  "objectRef": {
    "resource": "pods",
    "namespace": "prod",
    "name": "payment-pod",
    "subresource": "exec"
  },
  "responseStatus": {"code": 101},
  "requestReceivedTimestamp": "2026-11-25T10:30:01Z",
  "stageTimestamp": "2026-11-25T10:30:01Z",
  "sourceIPs": ["10.244.1.5"]
}
```

**What to look for during IR:**

```bash
# Find all exec events in the last hour
grep '"subresource": "exec"' /var/log/apiserver/audit.log \
  | grep "2026-11-25T10" | head -20

# Find secret reads by unexpected SAs
grep '"secrets"' /var/log/apiserver/audit.log \
  | grep -v '"verb": "watch"' \
  | grep '"username": "system:serviceaccount' \
  | head -50

# Find RBAC modifications (someone may have escalated their own access)
grep '"clusterrolebindings"' /var/log/apiserver/audit.log \
  | grep -E '"verb": "(create|patch|update)"'

# Timeline reconstruction: all events from a specific SA
grep '"username": "system:serviceaccount:dojo-poc:attacker-sa"' /var/log/apiserver/audit.log \
  | python3 -c "
import sys, json
for line in sys.stdin:
  e = json.loads(line.strip())
  print(e['requestReceivedTimestamp'], e['verb'], e.get('objectRef', {}).get('resource'), e.get('requestURI', ''))
"
```

---

## PICERL — Incident Response Framework

When something goes wrong, don't panic and start deleting things. Follow a structured process.

```
P — Prepare        (before the incident: playbooks, tools, access)
I — Identify       (confirm you have an incident, scope it)
C — Contain        (stop the bleeding, limit blast radius)
E — Eradicate      (remove the attacker's presence, patch the vuln)
R — Recover        (restore to known-good state, verify)
L — Learn          (post-incident review, improve controls)
```

### Full IR Runbook: Container Escape Scenario

**Day 0: Falco Alert Fires**

```
Alert: Terminal shell in container
  container=payment-pod
  image=company/payments:1.2.3
  user=root
  proc=sh
  node=node-2
```

#### I — Identify

```bash
# 1. Confirm the alert is real (not a false positive from a debug session)
kubectl get pod payment-pod -n prod -o yaml | grep -E "(serviceAccount|image|securityContext)"
kubectl logs payment-pod -n prod --previous 2>/dev/null | tail -20

# 2. Check what process is running in the pod right now
kubectl exec -n prod payment-pod -- ps aux
# If you see unexpected processes (nc, python3, /tmp/backdoor): confirmed compromise

# 3. Look at audit logs for what happened before the alert
grep '"name": "payment-pod"' /var/log/apiserver/audit.log | tail -20

# 4. Check if the pod escaped to the host
kubectl exec -n prod payment-pod -- cat /proc/1/cgroup
# If PID 1's cgroup shows the HOST's cgroups, the container has access to the host

# 5. Check if the node is compromised
kubectl describe node node-2 | grep -A5 "Conditions:"
```

#### C — Contain

```bash
# 1. Isolate the pod immediately (NetworkPolicy to drop all ingress/egress)
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: isolate-compromised-pod
  namespace: prod
spec:
  podSelector:
    matchLabels:
      app: payments
  policyTypes: [Ingress, Egress]
  # No ingress/egress rules = deny all traffic
EOF

# 2. Cordon the node (stop new pods being scheduled there)
kubectl cordon node-2

# 3. Preserve evidence BEFORE deleting anything
kubectl describe pod payment-pod -n prod > /tmp/evidence/pod-describe.txt
kubectl logs payment-pod -n prod > /tmp/evidence/pod-logs.txt
kubectl get events -n prod --sort-by='.lastTimestamp' > /tmp/evidence/events.txt

# 4. Label the pod for tracking
kubectl label pod payment-pod -n prod dojo.incident/status=contained
```

#### E — Eradicate

```bash
# 1. Delete the compromised pod
kubectl delete pod payment-pod -n prod

# 2. If a Deployment: scale to 0 immediately
kubectl scale deployment payments -n prod --replicas=0

# 3. Rotate ALL credentials the pod had access to
#    - Database passwords touched by the pod
#    - SA tokens (create a new SA with the same permissions)
kubectl delete serviceaccount payments-sa -n prod
kubectl create serviceaccount payments-sa -n prod  # new token auto-generated

#    - Vault dynamic credentials: revoke all leases for the pod's SA
vault token revoke -accessor $(vault token lookup -accessor ...)
vault lease revoke -prefix database/creds/payments-role

# 4. Patch the vulnerability that was exploited
#    (e.g., update the container image to fix the CVE)
kubectl set image deployment/payments -n prod payments=company/payments:1.2.4

# 5. Remove any backdoors planted (new RBAC, CronJobs, etc.)
kubectl get clusterrolebindings | grep -v system | grep -v kubeadm
kubectl get cronjobs --all-namespaces
```

#### R — Recover

```bash
# 1. Redeploy from clean, known-good manifests in git
git checkout main -- k8s/deployments/payments.yaml
kubectl apply -f k8s/deployments/payments.yaml

# 2. Scale back up
kubectl scale deployment payments -n prod --replicas=3

# 3. Uncordon node only after confirming it's clean
# Check for new processes, new files in /tmp, new cron entries
# Then:
kubectl uncordon node-2

# 4. Verify service is healthy
kubectl rollout status deployment/payments -n prod
kubectl get pods -n prod | grep payments
```

#### L — Learn

```
Post-incident review (within 24 hours):
1. How did the attacker get initial access? (CVE? misconfiguration?)
2. How long was dwell time? (time from intrusion to Falco alert)
3. What data was accessed? (audit log review)
4. What controls would have prevented this?
   - Was the container running as root? (fix: runAsNonRoot: true)
   - Did it have excess capabilities? (fix: drop ALL capabilities)
   - Was there a NetworkPolicy? (fix: default-deny in namespace)
5. Add new Falco rules or OPA policies for the technique used
6. Update the IR playbook with what worked/didn't
```

---

## Network Forensics

```bash
# Capture traffic on the node interface where the pod is running
# (from the NODE, not the pod)
NODE_IP=$(kubectl get pod payment-pod -n prod -o jsonpath='{.status.hostIP}')
ssh $NODE_IP "tcpdump -i eth0 -w /tmp/capture.pcap host <pod-ip> &"

# Or from inside the pod before killing it (if not yet isolated):
kubectl exec -n prod payment-pod -- \
  tcpdump -i eth0 -w /tmp/net-capture.pcap -c 1000 &

# Check active connections from inside the pod
kubectl exec -n prod payment-pod -- netstat -tlnp 2>/dev/null
kubectl exec -n prod payment-pod -- ss -tlnp
```

---

## CIS Hardening Quick Reference

```bash
# Run these post-incident (or proactively) to harden the cluster:

# 1. Disable automounting SA tokens cluster-wide by default
kubectl patch serviceaccount default -n prod -p '{"automountServiceAccountToken": false}'

# 2. Enable PodSecurity admission (built-in K8s 1.23+)
kubectl label namespace prod pod-security.kubernetes.io/enforce=restricted

# 3. Apply default-deny NetworkPolicy to every namespace
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: prod
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
EOF

# 4. Remove over-permissioned ClusterRoleBindings
kubectl get clusterrolebindings -o wide | grep "cluster-admin"
# Review each one — only kubeadm and system: entries should have cluster-admin

# 5. Enable audit logging (modify kube-apiserver manifest)
# Add flags to /etc/kubernetes/manifests/kube-apiserver.yaml:
# - --audit-log-path=/var/log/apiserver/audit.log
# - --audit-policy-file=/etc/kubernetes/audit-policy.yaml
# - --audit-log-maxage=30
```

---

## Checkpoint

1. What is kube-bench and what does a "FAIL" result in its output mean?
2. What is the purpose of `--anonymous-auth=false` on the API server?
3. What does Kubernetes audit logging capture that Falco does NOT?
4. In an audit log event, what field tells you which ServiceAccount made the API call?
5. What does "containment" mean in the PICERL framework — specifically in a Kubernetes context?
6. Why should you preserve evidence (pod logs, describe output) BEFORE deleting a compromised pod?
7. After rotating a ServiceAccount (deleting and recreating it), what credential specifically is invalidated?
8. What is `kubectl cordon <node>` and why do you do it during an incident?
9. If an attacker planted a CronJob as a persistence mechanism, how would you find it?
10. What is the minimum audit log level to capture who accessed which Kubernetes Secrets?

➡ Next: **The Red Team Lab** — the final boss: attack a deliberately misconfigured cluster, then harden it completely.
