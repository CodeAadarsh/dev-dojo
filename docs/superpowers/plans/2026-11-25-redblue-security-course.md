# Red Team / Blue Team Security Mastery — Course 38 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build `course-38-redblue-security` — a full Red Team / Blue Team cloud-native security course covering the MITRE ATT&CK kill chain, Falco runtime detection, zero trust with SPIFFE/SPIRE, Vault secrets, DevSecOps pipeline security, OPA/Kyverno policy, incident response, and a deliberately vulnerable Red Team lab — 12 modules, 15 challenges, per-module lab scripts.

**Architecture:** New course directory `courses/course-38-redblue-security/`. Adds a `labs/` subdirectory inside the course for per-module lab setup scripts. Adds `labs/bootstrap/install-vulnerable-lab.sh` for the full vulnerable cluster. Builds ON TOP of courses 03 (K8s attack/defend) and 30 (supply chain) — references them, doesn't repeat them.

**Tech Stack:** Markdown, Bash, kubectl, Falco, OPA/Gatekeeper, Kyverno, Vault, SPIRE, cosign, kube-bench, GitHub Actions, kind

**Spec:** `CONTENT_SPEC.md` in repo root.

## Global Constraints

- Course ID: `course-38-redblue-security`
- Flag format: `KUBE{lower_snake_case}` — tokens read as the lesson
- `flag.sha256` with `printf '%s' 'KUBE{...}' | shasum -a 256 | awk '{print $1}'` — no trailing newline
- `setup.sh`: `set -euo pipefail`, idempotent, namespace `dojo-sec-*`
- `verify.sh`: `set -uo pipefail`, `fail()` helper, kubectl + POSIX only (no jq — jsonpath)
- Audience: SDE who has done courses 01, 03, 30 — skip basics, go deep on attack methodology and enterprise defense
- Language: hacker mindset for red modules, ops mindset for blue modules — always explain the WHY
- Each module has its own lab script at `courses/course-38-redblue-security/labs/NN-topic-lab.sh`

## Flags (verbatim)

| Slug | Flag |
|------|------|
| 01-imds-credential-theft | `KUBE{imds_creds_live_on_169_254_169_254}` |
| 02-audit-log-forensics | `KUBE{audit_logs_never_lie}` |
| 03-falco-tripwire | `KUBE{falco_sees_the_shell_spawn}` |
| 04-opa-policy-escape | `KUBE{opa_constraints_must_be_strict}` |
| 05-ci-injection | `KUBE{github_actions_injection_via_pr_title}` |
| 06-vault-dynamic-creds | `KUBE{vault_leases_expire_creds_dont}` |
| 07-spiffe-attestation | `KUBE{spiffe_svid_proves_workload_identity}` |
| 08-kube-bench-cis | `KUBE{cis_benchmark_level1_pass}` |
| 09-runtime-evasion | `KUBE{falco_rules_have_blind_spots}` |
| 10-lateral-movement-chain | `KUBE{three_hops_to_node_compromise}` |
| 11-supply-chain-inject | `KUBE{sbom_diff_reveals_injected_package}` |
| 12-admission-gauntlet | `KUBE{five_policies_block_five_attacks}` |
| 13-mtls-intercept | `KUBE{mtls_encrypts_the_lateral_path}` |
| 14-incident-playbook | `KUBE{detect_contain_recover_in_order}` |
| 15-redteam-lab-boss | `KUBE{full_kill_chain_owned_then_hardened}` |

## Review Focus

- `verify.sh` no-jq: all JSON parsing via `-o jsonpath`, never `jq`
- Namespace naming: `dojo-sec-*` prefix throughout
- Lab scripts must be idempotent and self-contained — re-running must not error
- Red team challenges: setup.sh plants a genuinely exploitable misconfiguration (not fake)
- Boss challenge (15): verifier must check BOTH attack (flag discovered) AND hardening (security posture verified)

---

## Task 0: Scaffold

- [ ] Create `courses/course-38-redblue-security/course.json`
- [ ] Create all 15 challenge directories
- [ ] Create `courses/course-38-redblue-security/labs/` directory
- [ ] Generate all 15 `flag.sha256` files
- [ ] Generate all 15 `challenge.json` files
- [ ] Create `labs/bootstrap/install-vulnerable-lab.sh`
- [ ] Commit scaffold

## Task 1: Modules 01–06 (Kill Chain + Cloud)

Files: `modules/01` through `modules/06`

- 01: MITRE ATT&CK for Containers — full kill chain diagram, tactic-to-K8s mapping
- 02: Reconnaissance & Initial Access — service scanning, exposed dashboards, default tokens
- 03: Execution, Privilege Escalation & Persistence — capability abuse, hostPID, backdoor SA
- 04: Lateral Movement & Data Exfiltration — token pivoting, namespace hopping, secrets exfil
- 05: Cloud IAM & Metadata Service Attacks — IMDS, IRSA, instance profile abuse, resource-based policies
- 06: Runtime Detection with Falco — rule syntax, default ruleset gaps, writing custom rules

## Task 2: Modules 07–12 (Defense + Hardening)

Files: `modules/07` through `modules/12`

- 07: Zero Trust with SPIFFE/SPIRE + mTLS — SVID issuance, workload attestation, Istio/Cilium integration
- 08: Secrets Management with Vault — dynamic DB creds, PKI, transit, ESO sync
- 09: DevSecOps Pipeline Security — CI/CD attack surface, Actions injection, SAST/DAST/SCA in pipeline
- 10: Policy as Code: OPA Gatekeeper + Kyverno — ConstraintTemplates, ClusterPolicies, mutation
- 11: CIS Hardening + Incident Response — kube-bench, audit log analysis, containment runbook
- 12: The Red Team Lab — deliberate vuln cluster, full attack walkthrough, full hardening guide

## Task 3: Challenges 01–08 (Medium/Hard)

Per challenge: brief.md, solution.md, hints.json, setup.sh, verify.sh (verifier) or none (discovery), flag.sha256 (pre-generated)

## Task 4: Challenges 09–15 (Hard/Insane)

## Task 5: Per-module lab scripts + vulnerable lab bootstrap

Files: `courses/course-38-redblue-security/labs/01-kill-chain-lab.sh` through `12-redteam-lab.sh`
File: `labs/bootstrap/install-vulnerable-lab.sh`

## Task 6: Commit + push
