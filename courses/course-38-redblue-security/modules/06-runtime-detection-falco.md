# Runtime Detection with Falco — Catching Attackers in the Act

> **Module 06 · Course 38** — The attacker is inside your cluster. They exploited a vulnerability, got a pod shell, and are running commands. Every one of those commands is a system call. `execve()` to run a binary. `open()` to read a file. `connect()` to reach out over the network. Falco sits at the kernel level and watches every syscall every container makes. When the pattern matches a known attack technique, it fires an alert. This is runtime security — not static analysis, not image scanning, but live detection of attacker behavior as it happens.

---

## What Falco Is

Falco is a CNCF graduated project by Sysdig. It hooks into the Linux kernel using either:
- **eBPF probe** (recommended): loads a program into the kernel that captures syscalls, no kernel module needed
- **Kernel module**: traditional approach, requires loading a `.ko` file

Either way, the flow is:

```
Container runs: kubectl exec -it pod -- /bin/sh

Inside the kernel:
  Process in container calls: execve("/bin/sh", ...)
  │
  ▼
  eBPF probe captures: {syscall: execve, pid: 1234, comm: sh, container_id: abc123...}
  │
  ▼
  Falco engine: match against rules
  │
  ▼
  Rule "Terminal shell in container":
    condition: evt.type = execve and container.id != host and proc.name in (sh, bash, zsh, ...)
    MATCH → fire alert
  │
  ▼
  Output: JSON alert → stdout / file / webhook / Slack / PagerDuty
```

Falco can't stop the action (it's not an admission controller). But it generates an alert in near-real-time — typically within milliseconds of the syscall.

---

## Falco Rule Syntax

A Falco rule file is YAML. The main components:

```yaml
# A list — reusable list of values
- list: shell_binaries
  items: [sh, bash, zsh, dash, ksh, fish]

# A macro — reusable condition fragment  
- macro: container
  condition: (container.id != host)

- macro: spawned_process
  condition: (evt.type = execve and evt.dir = <)

# A rule — the actual detection
- rule: Terminal shell in container
  desc: A shell was opened in a container
  condition: >
    spawned_process
    and container
    and proc.name in (shell_binaries)
    and not proc.pname in (shell_binaries)
  output: >
    Shell opened in container
    (user=%user.name container=%container.name image=%container.image.repository
     shell=%proc.name parent=%proc.pname cmdline=%proc.cmdline)
  priority: WARNING
  tags: [container, shell, T1059]
```

**Key condition fields:**

| Field | Meaning | Example |
|-------|---------|---------|
| `evt.type` | syscall name | `execve`, `open`, `connect`, `write` |
| `container.id` | container ID (or "host" if not in container) | `abc123def456` |
| `container.name` | container name | `nginx` |
| `container.image.repository` | image name | `nginx` |
| `proc.name` | process name | `sh`, `curl` |
| `proc.pname` | parent process name | `bash` |
| `proc.cmdline` | full command line | `curl http://169.254.169.254/...` |
| `fd.name` | file/socket descriptor name | `/etc/shadow`, `169.254.169.254:80` |
| `fd.sip` | remote socket IP | `169.254.169.254` |
| `user.name` | user inside the container | `root`, `nobody` |

---

## Default Ruleset — Key Rules to Know

Falco ships with ~100 default rules. The most important ones for K8s security:

```
Rule: Terminal shell in container
  T1059 — detects kubectl exec and direct shell spawns
  condition: execve in container, process is a shell binary

Rule: Write below etc
  T1565 — filesystem modification in /etc
  condition: write/rename/chmod in /etc

Rule: Read sensitive file trusted after startup
  T1083 — /etc/shadow, /etc/passwd read post-startup
  condition: open /etc/shadow not by known system processes

Rule: Launch Privileged Container
  T1610 — container started with --privileged
  condition: container.privileged = true at start

Rule: Container Drift Detected (EE feature)
  T1105 — binary executed that wasn't in original image
  condition: proc.is_exe_upper_layer = true (file from writable overlay layer)

Rule: Outbound Connection to C2 Servers
  Custom — connection to known bad IPs
  condition: fd.sip in (known_c2_ips)

Rule: Modify binary dirs
  T1543 — write to /bin, /usr/bin, /sbin
  condition: write in /bin or /usr/bin or /sbin

Rule: Create files below dev
  T1552 — write in /dev (classic host escape indicator)
  condition: write evt.dir.name starts with /dev
```

---

## Writing a Custom Falco Rule

The default ruleset won't catch everything. Write your own:

**Example 1: Detect IMDS access**

```yaml
- rule: IMDS Credential Access
  desc: A container process connected to the cloud metadata service (169.254.169.254)
  condition: >
    evt.type in (connect, sendto)
    and container
    and fd.sip = "169.254.169.254"
  output: >
    IMDS access from container
    (user=%user.name container=%container.name image=%container.image.repository
     proc=%proc.name cmdline=%proc.cmdline conn=%fd.name)
  priority: CRITICAL
  tags: [container, cloud, imds, T1552.005]
```

**Example 2: Detect curl/wget in containers (C2 callback or exfil)**

```yaml
- list: http_tools
  items: [curl, wget, python3, python, nc, ncat, netcat]

- rule: Outbound HTTP tool in container
  desc: A container process ran curl, wget, or netcat
  condition: >
    spawned_process
    and container
    and proc.name in (http_tools)
    and not proc.pname in (sh, bash, make, docker)
  output: >
    HTTP tool launched in container
    (user=%user.name container=%container.name proc=%proc.name cmdline=%proc.cmdline)
  priority: WARNING
  tags: [container, network, T1071]
```

**Example 3: Detect SA token reads (credential theft)**

```yaml
- macro: serviceaccount_token_path
  condition: fd.name startswith "/var/run/secrets/kubernetes.io/serviceaccount"

- rule: Container reads Kubernetes service account token
  desc: A process read the mounted SA token (attacker pivoting)
  condition: >
    evt.type = open
    and container
    and serviceaccount_token_path
    and not proc.name in (java, node, python3, python, ruby, go)
  output: >
    Service account token read
    (user=%user.name container=%container.name proc=%proc.name
     file=%fd.name cmdline=%proc.cmdline)
  priority: WARNING
  tags: [container, credentials, T1528]
```

---

## Falco in Kubernetes: DaemonSet Deployment

Falco runs as a DaemonSet so there's one instance per node:

```bash
# Install with Helm
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm repo update
helm install falco falcosecurity/falco \
  --namespace falco \
  --create-namespace \
  --set driver.kind=ebpf \
  --set falco.grpc.enabled=true \
  --set falco.grpcOutput.enabled=true

# Check it's running (one pod per node)
kubectl get pods -n falco -o wide
# NAME                READY   STATUS    NODE
# falco-abc12         1/1     Running   node-1
# falco-xyz98         1/1     Running   node-2

# Watch live alerts
kubectl logs -n falco -l app.kubernetes.io/name=falco -f | grep -v "^$"
```

---

## Falco Alert Output Formats

```bash
# Default text output:
# 10:30:01.234 Warning Terminal shell in container (user=root container=nginx...)

# JSON output (better for SIEM):
{
  "time": "2026-11-25T10:30:01.234Z",
  "rule": "Terminal shell in container",
  "priority": "Warning",
  "output_fields": {
    "container.name": "nginx",
    "container.image.repository": "nginx",
    "proc.name": "sh",
    "proc.cmdline": "sh",
    "user.name": "root"
  },
  "hostname": "node-1"
}
```

**Sending alerts to Slack/PagerDuty:**

```yaml
# In falco.yaml or via Helm values:
json_output: true
json_include_output_property: true

# Falcosidekick handles routing:
helm install falcosidekick falcosecurity/falcosidekick \
  --namespace falco \
  --set config.slack.webhookurl="https://hooks.slack.com/services/..." \
  --set config.pagerduty.routingKey="xxxx"

# Now alerts appear in Slack as:
# [WARNING] Terminal shell in container
# container=nginx image=nginx user=root proc=sh
```

---

## Falco Gaps — What It Doesn't Catch

Falco is powerful but it has blind spots. Knowing them is important for both red and blue teams:

**Gap 1: kubectl API reads don't go through container syscalls**

```bash
# From OUTSIDE the cluster (attacker's machine):
kubectl get secret db-creds -n prod
# This calls the Kubernetes API server — no process runs inside any container
# No syscall in any container → Falco doesn't see it
# Only the K8s audit log captures this
```

**Gap 2: Rules can have exceptions that an attacker exploits**

Default rules have whitelists to avoid false positives. For example:

```yaml
- rule: Write below etc
  condition: >
    write_etc_dirs
    and not proc.name in (dpkg, apt, yum, rpm, chef, puppet, ansible)
    #                     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
    # If the attacker renames their binary to "dpkg", this rule doesn't fire
```

**Gap 3: Cryptomining via legitimate processes**

```bash
# If an attacker uses a legitimate process (e.g., python3) to mine crypto:
python3 -c "import subprocess; subprocess.run(['./xmrig', '--pool', 'mining.pool.com'])"
# The execve of xmrig may be caught, but if xmrig is renamed to "python3":
mv xmrig python3
./python3   # exec of "python3" — matches the exception list
```

**Gap 4: Time-of-check vs time-of-use**

Falco fires *after* the syscall. It can alert that a shell was spawned, but the attacker already ran commands during the alert's propagation delay.

**Gap 5: Rules must be enabled and tuned**

Default Falco ships with many rules disabled or at LOW priority. Without customization, high-severity events may go unnoticed in the noise.

---

## Falco Alert Lifecycle

```
Attacker action
      │
      ▼ milliseconds
Syscall in kernel
      │
      ▼ <1ms
eBPF probe captures + sends to Falco engine
      │
      ▼ <5ms
Rule match → alert fired
      │
      ▼ network hop
Falcosidekick → Slack/PagerDuty/SIEM
      │
      ▼ human latency
SOC analyst sees alert (minutes to hours later)
      │
      ▼ investigation
Incident response begins

Attacker has had: seconds to minutes of undetected time
Falco is about DETECTION, not prevention.
```

The goal isn't to stop the attacker with Falco — it's to reduce the dwell time (time between compromise and detection) to minutes instead of months.

---

## Checkpoint

1. What is eBPF and why does Falco use it instead of always requiring a kernel module?
2. What are the four required fields in a Falco rule?
3. What syscall does `kubectl exec -it pod -- /bin/sh` ultimately trigger that Falco detects?
4. What is the difference between a Falco `list`, `macro`, and `rule`?
5. Write the condition part of a Falco rule that detects any process reading `/etc/shadow`.
6. Why can't Falco detect an attacker reading a Kubernetes Secret via `kubectl get secret`?
7. If an attacker renames their binary to `dpkg`, which default Falco rule becomes ineffective?
8. What is Falcosidekick and what does it add to a basic Falco installation?
9. What field in a Falco condition would you use to detect a connection to `169.254.169.254`?
10. If you want to detect lateral movement via stolen SA tokens, would you use Falco or the K8s audit log? Why?

➡ Next: **Zero Trust with SPIFFE/SPIRE** — Falco detects after the fact; zero trust prevents the lateral movement in the first place.
