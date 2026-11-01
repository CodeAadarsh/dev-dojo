# Detect and Fix Configuration Drift

3 am. An alert fires: your service is logging at `debug` level and generating 40× the usual log volume. You track it down to `app-config.txt` — it's been modified directly on the machine by a teammate doing "a quick hotfix." The Terraform state still thinks it contains the managed content. This gap between what Terraform **believes** is deployed and what is **actually** there is called **configuration drift**, and it is the most common way IaC erodes into chaos.

Your job: learn to detect drift with `terraform plan -detailed-exitcode`, understand what the exit codes mean, and restore the managed state with `terraform apply`.

## Context

`setup.sh` plants a starter project in your work directory:

```
~/.kube-dojo-work/05-detect-the-drift/
└── main.tf       # single local_file resource managing app-config.txt
```

## Prerequisites

```bash
cd ~/.kube-dojo-work/05-detect-the-drift
terraform init
```

Terraform 1.5+ and internet once for provider download (hashicorp/local ~2.4).

## Drift — the mental model

Terraform's state file is a **snapshot** of what it last applied. The `plan` phase refreshes state by reading real infrastructure and diffing against the desired config. When the real world diverges from state, Terraform surfaces it as a pending change:

```
  ~ resource "local_file" "config" {
      ~ content = <<-EOT
          - environment = corrupted   # what's actually on disk
          + environment = production  # what Terraform will restore
        EOT
    }
```

`terraform plan -detailed-exitcode` encodes the result in the exit code:

| Exit code | Meaning |
|-----------|---------|
| `0` | Success, no changes |
| `1` | Error (syntax, provider issue) |
| `2` | Success, **changes pending** (drift or config edit) |

Exit code 2 is your drift alarm. In CI pipelines, `terraform plan -detailed-exitcode` with a `|| [ $? -eq 2 ]` guard is how automated drift detection works without blocking the build on legitimate pending changes.

## Mission (hands-on before verify.sh)

Work through the sequence manually so the concepts stick — `verify.sh` will re-run the same sequence automatically.

```bash
cd ~/.kube-dojo-work/05-detect-the-drift

# 1. Apply the managed config
terraform apply -auto-approve
cat app-config.txt          # should show managed content

# 2. Simulate out-of-band change (a teammate's "quick fix")
printf 'environment = corrupted\nlog_level = debug\nreplicas = 1\n' > app-config.txt

# 3. Detect drift — what exit code do you get?
terraform plan -detailed-exitcode
echo "Plan exit code: $?"   # expect 2

# 4. Inspect what Terraform will change
terraform plan              # shows the diff in human-readable form

# 5. Restore managed state
terraform apply -auto-approve
grep "environment = production" app-config.txt && echo "restored"
```

The `verify.sh` checks exactly:

1. Initial apply succeeds and creates `app-config.txt`.
2. The file is mutated out-of-band (by the verifier itself).
3. `terraform plan -detailed-exitcode` exits with code **2** (drift detected).
4. A follow-up apply exits **0** and restores `app-config.txt` to contain `environment = production`.

Your `main.tf` must declare the resource correctly for all four checks to pass. The stub is nearly complete — only `filename` and `content` need to be set if they are missing.

## Why this matters at your scale

At SAP, every service that writes a config file is a drift candidate. A hotfix applied to one replica, a manual `kubectl edit` on a ConfigMap, an operator touching `/etc/` — all of these are drift events. The pattern is: IaC defines intent; reality drifts; plan detects; apply reconciles. Terraform's model is identical to Kubernetes' control loop: desired state vs observed state, continuously reconciled.

## Verify

```bash
bash courses/course-23-terraform-iac/challenges/05-detect-the-drift/verify.sh
```

All checks green → flag printed.
