# Challenge 09 — Runtime Evasion

**Difficulty:** Hard | **Type:** Discovery | **Est. Time:** 45 min

---

## Situation

Falco is watching. Every shell spawn, every suspicious file read, every privilege escalation attempt — Falco sees it.

You're on the red team. Your objective is to read the flag from the `evasion-flag` Secret in namespace `dojo-sec-evasion` **without triggering a Falco shell detection alert**.

The catch: the pod `red-team-pod` is running `python3` as its entrypoint. There's no `sh` or `bash` in the image. And Falco's default rules fire on `proc.name in (sh, bash, zsh, dash, ksh, tcsh, csh)`.

What other ways can you read a file without spawning a *named* shell?

---

## Lab Setup

```bash
kubectl apply -f - <<'EOF'
# Run setup.sh first
EOF
bash setup.sh
```

Or:
```bash
bash courses/course-38-redblue-security/challenges/09-runtime-evasion/setup.sh
```

---

## Your Goal

Read the flag from the Secret `evasion-flag` in namespace `dojo-sec-evasion`, key `flag`.

The flag is the value of that secret. Access it using a technique Falco's default ruleset **does not** detect.

**Proof of learning:** understand *why* the technique evades Falco, then read `evasion-hints` ConfigMap to verify your understanding matches.

---

## What You'll Learn

- Falco's default detection rules and their blind spots
- Non-shell code execution (Python, Perl, `awk`, `find -exec`)
- Why syscall-level detection (eBPF) catches what name-based detection misses
- How blue teams tune Falco rules to close these gaps

---

## Rules

- Do not modify or delete Falco rules
- Do not delete the `evasion-flag` Secret
- Do not use `kubectl get secret` directly — `exec` into the pod and read it from the mounted volume
