#!/usr/bin/env bash
# Plants the "Iterate With for_each" starter project into the work directory.
# Idempotent — re-running overwrites .tf files but does not touch .terraform/.
set -euo pipefail

SLUG="04-count-and-for-each"
WORK="$HOME/.kube-dojo-work/$SLUG"
mkdir -p "$WORK"

# ── main.tf skeleton ─────────────────────────────────────────────────────────
cat > "$WORK/main.tf" << 'TFEOF'
terraform {
  required_providers {
    local = {
      source  = "hashicorp/local"
      version = "~> 2.4"
    }
  }
}

locals {
  # Map of service name -> description.
  # Do NOT change these values — verify.sh checks exact content.
  services = {
    "auth-service"    = "Handles authentication and token issuance"
    "payment-service" = "Processes transactions and refunds"
    "catalog-service" = "Manages product listings and inventory"
  }
}

# TODO: replace for_each = {} with local.services
# TODO: set filename to "${path.module}/output/<key>.txt"
# TODO: set content to "Service: <key>\nDescription: <value>\n"
resource "local_file" "service_manifest" {
  for_each = {}   # stub — creates zero files; replace with local.services
  filename = "${path.module}/output/${each.key}.txt"
  content  = "Service: FIXME\nDescription: FIXME\n"
}
TFEOF

# ── outputs.tf ───────────────────────────────────────────────────────────────
cat > "$WORK/outputs.tf" << 'TFEOF'
output "service_count" {
  description = "Number of service manifest files written"
  value       = length(local_file.service_manifest)
}

output "service_files" {
  description = "Map of service name to absolute file path"
  value       = { for k, v in local_file.service_manifest : k => v.filename }
}
TFEOF

echo ""
echo "Work directory : $WORK"
echo ""
echo "Task           : edit main.tf so for_each drives all three service_manifest"
echo "                 resources from local.services. Each file must land in"
echo "                 output/<key>.txt with Service: and Description: lines."
echo ""
echo "Prerequisites  : terraform 1.5+, internet once for provider download"
echo ""
echo "Initialize     : cd $WORK && terraform init"
echo "Plan           : terraform plan"
echo "Apply          : terraform apply -auto-approve"
echo "Verify + flag  : bash courses/course-23-terraform-iac/challenges/$SLUG/verify.sh"
