# Solution — Detect and Fix Configuration Drift

The `main.tf` planted by `setup.sh` is already correct — no edits are required. The resource is fully defined:

```hcl
resource "local_file" "config" {
  filename = "${path.module}/app-config.txt"
  content  = <<-EOT
    environment = production
    log_level   = info
    replicas    = 3
  EOT
}
```

The challenge is about **understanding** the workflow, not writing HCL. The verifier runs the drift detection sequence for you automatically. Here is the manual walkthrough with the important details.

## Step 1: Apply

```bash
cd ~/.kube-dojo-work/05-detect-the-drift
terraform init
terraform apply -auto-approve
cat app-config.txt
```

Terraform writes `app-config.txt` and records the content hash in `terraform.tfstate`. The state file is Terraform's memory of what it last applied.

## Step 2: Mutate out-of-band

```bash
printf 'environment = corrupted\nlog_level = debug\nreplicas = 1\n' > app-config.txt
```

This is the "teammate's hotfix." The file on disk now differs from the state. Terraform doesn't know yet.

## Step 3: Detect drift

```bash
terraform plan -detailed-exitcode
echo "Exit: $?"   # -> 2
```

During the `plan` phase, Terraform **refreshes** state by reading the real file. It sees the mismatch, computes a diff, and reports it. The `-detailed-exitcode` flag encodes the result:

- `0` — no changes (clean)
- `1` — Terraform error (bad HCL, provider issue)
- `2` — changes pending (this is your drift alarm)

The plan output shows the exact diff — what Terraform will restore vs what is on disk. This is the moment to decide: apply (restore) or import (accept the current state as desired). For a managed config file, restore is almost always correct.

## Step 4: Restore

```bash
terraform apply -auto-approve
grep "environment = production" app-config.txt && echo "restored"
```

Apply reconciles reality to the declared state. The file is rewritten with the managed content.

## Why `-detailed-exitcode` matters in CI

In a pipeline you cannot interactively inspect exit code from a wrapped script. The pattern:

```bash
terraform plan -detailed-exitcode -out=plan.tfplan
PLAN_RC=$?
if [ "$PLAN_RC" -eq 1 ]; then
  echo "Terraform error" && exit 1
elif [ "$PLAN_RC" -eq 2 ]; then
  echo "Drift or pending changes detected — review plan.tfplan"
  # gate on human approval or auto-apply depending on environment
fi
```

This is the basis of every GitOps Terraform pipeline: plan on PR open, apply on merge, drift detection on schedule.

## Attacker's note

An attacker who can write to a Terraform-managed file can cause `plan` to show a "change" that masks a malicious payload. If your pipeline does `plan` → `apply` automatically and the diff is large or confusing, the malicious content might slip through in the noise. Pinning content hashes and using OPA/Conftest policies on the plan JSON is the hardening path.
