# Falco Tripwire — Solution

## Reading the Simulated Alerts

```bash
kubectl get configmap falco-simulation -n dojo-sec-falco -o jsonpath='{.data.alerts}' | tr '{}' '\n' | grep rule
```

Three rules fired:
1. **Terminal shell in container** — `sh` was executed (T1059)
2. **Read sensitive file trusted after startup** — `/etc/shadow` was read (T1083)
3. **Package management processes spawned in container** — `apt install netcat-openbsd` (T1072)

---

## Writing the Custom Rule

The attacker ran `ls /usr/bin` before any of these events — checking what tools are available. The default ruleset doesn't alert on `ls` because it's too common. We need a custom rule.

Create `/tmp/custom-falco-rule.yaml`:

```yaml
- rule: Directory Listing in Container
  desc: >
    A process ran 'ls' inside a container — a common first step in attacker
    reconnaissance to discover available binaries and tools.
  condition: >
    evt.type = execve
    and container
    and proc.name = "ls"
    and not proc.pname in (sh, bash, make, docker-entrypoint)
  output: >
    Directory listing in container
    (user=%user.name container=%container.name image=%container.image.repository
     proc=%proc.name cmdline=%proc.cmdline parent=%proc.pname)
  priority: WARNING
  tags: [container, recon, T1082]
```

---

## Running the Verifier

```bash
bash verify.sh
```

Expected output:

```
==> Verifying: Falco Tripwire

==> Custom Falco rule validated. Structure is correct.
    The 3 simulated alerts show rule 'Terminal shell', 'Read sensitive file', and 'Package management'.
    Your rule would catch the pre-attack reconnaissance.

KUBE{falco_sees_the_shell_spawn}
```

**Flag: `KUBE{falco_sees_the_shell_spawn}`**

---

## Why the Default Rules Miss Reconnaissance

Falco's default rules are tuned to avoid false positives. `ls`, `ps`, `cat`, `find` are all used by legitimate processes constantly. If you alert on every `ls`, you'd drown in noise from health checks, init scripts, and log processors.

The fix for production:
- Establish a baseline of "normal" commands in your containers
- Alert on commands that are NOT in that baseline (e.g., `netcat`, `nmap`, `curl` to external IPs)
- Use the `container.image.repository` field to write image-specific rules (nginx should never run `apt`)
