#!/usr/bin/env bash
# Plants the "Detect and Fix Configuration Drift" starter into the work dir.
# Idempotent — re-running overwrites main.tf but preserves .terraform/.
set -euo pipefail

SLUG="05-detect-the-drift"
WORK="$HOME/.kube-dojo-work/$SLUG"
mkdir -p "$WORK"

# ── main.tf ───────────────────────────────────────────────────────────────────
cat > "$WORK/main.tf" << 'TFEOF'
terraform {
  required_providers {
    local = {
      source  = "hashicorp/local"
      version = "~> 2.4"
    }
  }
}

# Terraform manages this file. Any out-of-band edit is drift.
# Do NOT change the content value — verify.sh checks for "environment = production".
resource "local_file" "config" {
  filename = "${path.module}/app-config.txt"
  content  = <<-EOT
    environment = production
    log_level   = info
    replicas    = 3
  EOT
}
TFEOF

echo ""
echo "Work directory : $WORK"
echo ""
echo "Task           : understand and demonstrate Terraform drift detection."
echo "                 The resource is fully defined — run through the manual"
echo "                 sequence in the brief, then run verify.sh."
echo ""
echo "Prerequisites  : terraform 1.5+, internet once for provider download"
echo ""
echo "Initialize     : cd $WORK && terraform init"
echo "Apply          : terraform apply -auto-approve"
echo "Detect drift   : terraform plan -detailed-exitcode   # exit code 2 = drift"
echo "Verify + flag  : bash courses/course-23-terraform-iac/challenges/$SLUG/verify.sh"
