# Operational Secrets Hygiene

> **Module 07 · Course 31** — Knowing how to store secrets well is half the problem. The other half is operating them over time: rotating them before they're stale, detecting when they've already escaped, leaving an audit trail that makes the post-mortem possible, and knowing exactly what to do in the first 15 minutes after a breach.

This module is about the operational discipline that turns a good secrets architecture into one that actually survives contact with a real team — engineers who forget, CI pipelines that log too much, and the inevitable day when something ends up in a public repo.

---

## Rotation strategy and automation

### Why rotation matters even if the secret hasn't leaked

A credential that was issued six months ago has had six months to accumulate risk: it may have been logged somewhere, copied to a dev laptop, included in a snapshot, or handed to a third-party debugging session. Rotation doesn't fix a breach that already happened — it limits the window of an *undiscovered* breach.

Rotation goals:

| Credential type | Target rotation frequency | Mechanism |
|----------------|--------------------------|-----------|
| DB passwords (static) | ≤ 30 days | Vault dynamic secrets or Secrets Manager rotation lambda |
| API keys (third-party) | ≤ 90 days | Vault static secret + lease; human reminder in ticket system |
| TLS certs (internal) | ≤ 24 h (ideally 1 h) | cert-manager + SPIFFE/SPIRE; auto-rotate |
| TLS certs (public) | ≤ 90 days | cert-manager ACME (Let's Encrypt) |
| SSH/GPG signing keys | ≤ 1 year | Calendar reminder + runbook |
| SA tokens (Kubernetes) | Auto (kubelet rotates bound tokens) | Use bound token projection; never mount a legacy SA Secret |

### Zero-downtime rotation: the two-phase pattern

The hardest rotation problem is "I need to change the password without dropping live traffic." The answer is always: phase 1 = add, phase 2 = remove.

```
Phase 1 (dual-read):
  DB accepts BOTH old_password AND new_password
  Deploy app config with new_password
  Verify all pods are using new_password (kubectl rollout status)

Phase 2 (remove old):
  DB removes old_password
  Audit log confirms zero logins with old_password for ≥ 1 deploy cycle
```

In Vault, this maps to dynamic secrets: Vault's DB secrets engine creates a *new* credential for each lease and the old one is revoked at TTL expiry. There is no "rotation event" — every request gets a fresh credential:

```bash
# vault issues a new postgres credential; TTL = 1h; revoked automatically
vault read database/creds/payments-role
# Key           Value
# username      v-k8s-payments-AbCdEf
# password      A1b2C3d4E5f6-...
# lease_id      database/creds/payments-role/gHiJkL
# lease_duration 1h
```

The Pod gets this credential via the Vault Agent Sidecar or Vault Secrets Operator, which re-fetches it before expiry and rewrites the mounted file — zero-downtime, automatic.

### cert-manager for TLS rotation

cert-manager watches `Certificate` resources and renews certs at `renewBefore` (default: 1/3 of the cert lifetime):

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: payments-api-tls
  namespace: dojo-payments
spec:
  secretName: payments-api-tls-secret
  duration: 24h
  renewBefore: 8h
  dnsNames:
  - payments-api.dojo-payments.svc.cluster.local
  issuerRef:
    name: cluster-issuer
    kind: ClusterIssuer
```

`kubectl describe certificate payments-api-tls -n dojo-payments` shows the `Renewal Time` field. Set up an alert if a cert's `Not After` minus now is less than `renewBefore` — that means cert-manager is failing to renew.

---

## Leak detection: scanning for secrets

### Prevent at commit time — pre-commit hooks

```bash
# install gitleaks as a pre-commit hook
cat > .git/hooks/pre-commit << 'HOOK'
#!/usr/bin/env bash
if command -v gitleaks >/dev/null 2>&1; then
  gitleaks protect --staged --redact 2>&1 || { echo "✗ gitleaks found secrets — commit blocked"; exit 1; }
fi
HOOK
chmod +x .git/hooks/pre-commit
```

Gitleaks scans the staged diff (not the whole repo) and exits non-zero if it detects credentials. It understands 150+ secret patterns: AWS keys, GCP service account JSON, GitHub tokens, JWT secrets, etc.

### Scan the full history after the fact

```bash
# scan entire git history (takes a minute on large repos)
gitleaks detect --source . --report-format json --report-path gitleaks-report.json

# targeted: scan only since last known-clean commit
gitleaks detect --source . --log-opts "v1.2.3..HEAD"
```

Trufflehog goes deeper — it checks entropy and follows git object references:

```bash
# scan a GitHub repo (replace with your org/repo)
trufflehog git https://github.com/your-org/payments --only-verified --json 2>/dev/null | \
  python3 -c "import sys,json; [print(json.dumps(r, indent=2)) for r in (json.loads(l) for l in sys.stdin) if r.get('Verified')]"
```

`--only-verified` means trufflehog actually *calls the API* with the found credential to confirm it's live — a false-positive filter that catches the difference between a rotated key in history (dead) and an active one (emergency).

### CI integration

Add to your GitHub Actions pipeline:

```yaml
- name: Secret scan
  uses: gitleaks/gitleaks-action@v2
  env:
    GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
    GITLEAKS_LICENSE: ${{ secrets.GITLEAKS_LICENSE }}  # required for org-level
```

Or use `trufflehog` without a license:

```yaml
- name: TruffleHog
  uses: trufflesecurity/trufflehog@main
  with:
    path: ./
    base: ${{ github.event.repository.default_branch }}
    head: HEAD
    extra_args: --only-verified
```

---

## Audit logging

You cannot respond to what you cannot see. Audit logs answer: *who accessed which secret, when, from where.*

### Kubernetes API server audit

Add an audit policy to the API server (`/etc/kubernetes/manifests/kube-apiserver.yaml` on kind's control plane):

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
# log all secret reads at RequestResponse level
- level: RequestResponse
  resources:
  - group: ""
    resources: ["secrets"]
  verbs: ["get", "list", "watch"]
# log everything else at Metadata level (no request body)
- level: Metadata
```

```bash
# on the control-plane node
docker exec dojo-control-plane \
  tail -f /var/log/kubernetes/audit.log | \
  python3 -I -c "
import sys, json
for line in sys.stdin:
    try:
        e = json.loads(line)
        if e.get('objectRef', {}).get('resource') == 'secrets':
            print(e['stageTimestamp'], e['user']['username'], e['verb'],
                  e['objectRef'].get('namespace'), e['objectRef'].get('name'))
    except Exception:
        pass
"
```

This shows: every `get secrets` call, by whom, at what time. If `system:anonymous` appears — that's a critical misconfiguration alert.

### Vault audit

Vault writes an audit log to a file or syslog. Enable it:

```bash
vault audit enable file file_path=/vault/logs/audit.log
# or syslog, for forwarding to LGTM/Splunk
vault audit enable syslog tag=vault facility=AUTH
```

Every secret read, every lease issuance, every revocation appears in the audit log with the `display_name` (the SA or human identity that requested it). A Vault audit log is the only way to answer "did the DB cred for payments ever leave the cluster?"

---

## Break-glass access

Break-glass is the controlled, logged, and time-limited mechanism for emergency access to a system that is normally inaccessible. The three properties: **rare, logged, reviewed after the fact.**

### The anti-pattern: always-on admin access

Giving an SRE a permanent `cluster-admin` ClusterRoleBinding "just in case" violates least-privilege and means that SRE's compromised laptop is a full cluster-admin. The blast radius is the whole cluster.

### The pattern: just-in-time elevation

```bash
# Vault + Kubernetes auth: request a short-lived token with cluster-admin
vault write auth/kubernetes/role/break-glass \
  bound_service_account_names=break-glass-sa \
  bound_service_account_namespaces=dojo-ops \
  policies=break-glass \
  ttl=30m

# the break-glass Vault policy
path "secret/data/break-glass/*" { capabilities = ["read"] }
path "auth/token/renew-self" { capabilities = ["update"] }
```

The SRE requests the token via an approval workflow (PagerDuty → Vault → Slack approval → short-lived `kubeconfig`). The whole flow is audited in Vault. After the incident, the token expires automatically.

### Kubernetes RBAC: least-privilege by default

```yaml
# each namespace gets a namespace-admin role, not cluster-admin
kind: ClusterRole
metadata:
  name: namespace-admin
rules:
- apiGroups: ["*"]
  resources: ["*"]
  verbs: ["*"]
  # no nodes, no PVs, no CRDs at cluster scope
---
kind: RoleBinding   # namespaced, not ClusterRoleBinding
metadata:
  name: sre-namespace-admin
  namespace: dojo-payments
subjects:
- kind: Group
  name: sre-team
roleRef:
  kind: ClusterRole
  name: namespace-admin
```

Default: SREs can admin their namespaces. Cluster-scope access is break-glass only.

### Just-in-time with `kubectl auth can-i`

After granting temporary elevated access, verify the scope before using it:

```bash
kubectl auth can-i delete pods -n dojo-payments     # should be yes
kubectl auth can-i delete nodes                     # should be no during normal JIT
kubectl auth can-i "*" "*" --all-namespaces         # only yes during true break-glass
```

---

## Incident response: a secret leaked to a public repo

The exact sequence when you discover a secret in a public commit. Time matters — bots scrape GitHub in minutes.

```
T+0 min   Discover the commit
T+1 min   Revoke the credential (do this FIRST — before anything else)
T+2 min   Rotate / issue a new credential
T+5 min   Scan for downstream uses (audit logs, access logs)
T+15 min  Remove from git history (this is cosmetic after step 1, but required)
T+30 min  Assess blast radius, write incident report
```

### Step 1 — Revoke immediately

```bash
# AWS key
aws iam delete-access-key --access-key-id AKIAIOSFODNN7EXAMPLE

# GitHub PAT: revoke in Settings → Developer settings → Tokens
# or via API:
curl -s -X DELETE \
  -H "Authorization: token $GITHUB_PAT" \
  https://api.github.com/applications/$CLIENT_ID/token \
  -d '{"access_token":"'$LEAKED_TOKEN'"}'

# Vault: revoke all leases for the role
vault lease revoke -prefix auth/kubernetes/payments-role/

# Kubernetes SA token: delete the SA (old-style token) or rotate the SA
kubectl delete sa leaked-sa -n dojo-payments && kubectl apply -f sa.yaml
```

Revocation is immediate and irreversible. Every other step is forensic.

### Step 2 — Remove from git history

Removing from git history does NOT help if the repo was public and the commit is older than ~30 seconds. Bots have it. Revoke first.

```bash
# BFG Repo Cleaner (faster than git-filter-repo for secrets)
# run from a FRESH clone in a SEPARATE empty directory:
git clone --mirror https://github.com/org/repo repo-mirror
cd repo-mirror
java -jar /path/to/bfg.jar --replace-text /tmp/passwords.txt
git reflog expire --expire=now --all
git gc --prune=now --aggressive
git push --force

# passwords.txt format:
# AKIAIOSFODNN7EXAMPLE==>REMOVED
```

Or with `git filter-repo` (no Java required):

```bash
git filter-repo --path-glob '*.env' --invert-paths
git filter-repo --replace-text /tmp/expressions.txt
```

### Step 3 — Assess and document

```bash
# check CloudTrail for uses of the leaked key (AWS)
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=Username,AttributeValue=AKIAIOSFODNN7EXAMPLE \
  --start-time 2026-01-01T00:00:00Z \
  --output text

# check Vault audit for the leaked token
grep "leaked-token-display-name" /vault/logs/audit.log | \
  python3 -I -c "import sys,json; [print(json.loads(l)['time'], json.loads(l)['request']['path']) for l in sys.stdin]"
```

---

## Debugging Operational Secrets Hygiene

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Secret found in git history by gitleaks but `--only-verified` says it's dead | Credential was already rotated; history not cleaned | Run BFG to remove from history; no immediate security risk since credential is dead |
| Vault audit log is empty | Audit is not enabled (it's opt-in) | `vault audit enable file file_path=...`; confirm with `vault audit list` |
| `kubectl get events` shows a Secret being read by `system:unauthenticated` | Anonymous API server access is enabled | Add `--anonymous-auth=false` to kube-apiserver; audit which RBAC bound `system:anonymous` |
| cert-manager is not rotating an expiring cert | `renewBefore` is larger than the cert's remaining lifetime at issuance; or the ACME DNS solver is failing | `kubectl describe certificaterequest -n <ns>`; check `cert-manager` logs; verify DNS-01 records |
| Break-glass Vault token expires mid-incident | TTL too short; renewal not configured | Set `period` on the token role instead of `ttl` for operator tokens; use `vault token renew` during the incident; add reminder to runbook |
| No audit trail for who deleted a Secret | Kubernetes API audit policy not set to `RequestResponse` for `delete` verbs | Update audit policy to include `delete` verbs for secrets; redeploy API server config |

### Diagnosing "no audit trail"

```bash
# check if audit logging is enabled on the API server
docker exec dojo-control-plane \
  cat /etc/kubernetes/manifests/kube-apiserver.yaml | grep -A 3 audit

# if nothing appears, audit is off. Add these flags to the static pod manifest:
# --audit-policy-file=/etc/kubernetes/audit-policy.yaml
# --audit-log-path=/var/log/kubernetes/audit.log
# --audit-log-maxage=30
# --audit-log-maxbackup=3
# then the API server will restart automatically (it's a static pod)

# verify the audit log is being written
docker exec dojo-control-plane ls -lh /var/log/kubernetes/audit.log
docker exec dojo-control-plane wc -l /var/log/kubernetes/audit.log
```

> **War story.** A team at a previous project discovered one of their Slack bot tokens in a three-year-old commit. They spent two hours rewriting git history before revoking the token. In that window, the token was still valid and the bot had `channels:read` + `chat:write` on every Slack channel in the org. Gitleaks running in CI would have caught the original commit before it ever merged. Revoking first would have capped the exposure window at the discovery moment. The history rewrite was meaningless without the revoke — it just made the repo look cleaner while the token remained live. The sequence is always: **revoke, then investigate, then clean up.** History hygiene is a reputation concern, not a security control.

---

## Checkpoint

You're ready for the challenges when you can:

1. State the two-phase rotation pattern for a DB password and explain why both phases are needed (hint: one word — atomicity).
2. Name the command that confirms gitleaks found a live credential versus a rotated one already in history.
3. List the four things an API-server audit log records for a `get secrets` call that a Vault audit log does not, and vice versa.
4. Describe the three properties of break-glass access and name the RBAC primitive difference between namespace-scope and cluster-scope elevation.
5. Recite the leaked-secret response sequence from memory in the correct order — specifically: what is the one action you take before anything else, including forensics.
6. Write the `kubectl auth can-i` one-liners that confirm your JIT elevation is scoped correctly and hasn't been over-granted.
7. Diagnose "no audit trail": the one kube-apiserver flag that must be set and where to confirm it's taking effect inside the kind control-plane node.

➡ Course complete. You now have the full stack: secrets storage → external secrets → encryption → workload identity → zero-trust networking → operational hygiene. The next challenges put each layer under pressure — starting with **envelope encryption** and working through to **mTLS in Python** and **a full break-glass simulation**.
