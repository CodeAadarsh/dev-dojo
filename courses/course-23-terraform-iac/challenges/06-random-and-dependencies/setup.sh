#!/usr/bin/env bash
# Plants the "Random Values and Explicit Dependencies" starter into the work dir.
# Idempotent — re-running overwrites .tf files but preserves .terraform/.
set -euo pipefail

SLUG="06-random-and-dependencies"
WORK="$HOME/.kube-dojo-work/$SLUG"
mkdir -p "$WORK"

# ── main.tf skeleton ──────────────────────────────────────────────────────────
cat > "$WORK/main.tf" << 'TFEOF'
terraform {
  required_providers {
    local = {
      source  = "hashicorp/local"
      version = "~> 2.4"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}

# Step 1: Generate a stable random name (e.g. "brave-lynx") and a build ID hex string.
resource "random_pet" "app_name" {
  length    = 2
  separator = "-"
}

resource "random_id" "build_id" {
  byte_length = 4
}

# Step 2: Write both generated values into a deploy manifest file.
# TODO: set filename to "${path.module}/deploy-manifest.txt"
# TODO: set content to include both random_pet.app_name.id and random_id.build_id.hex
resource "local_file" "deploy_manifest" {
  filename = "${path.module}/deploy-manifest.txt"
  content  = "app_name = FIXME\nbuild_id = FIXME\n"
}

# Step 3: Use a null_resource to model a "post-deploy hook" that must run
# AFTER the manifest is written and must re-run when the manifest content changes.
# TODO: set triggers to a map that includes local_file.deploy_manifest.content
# TODO: add depends_on = [local_file.deploy_manifest]
# Keep the provisioner block below — the verifier does not check its output.
resource "null_resource" "post_deploy" {
  triggers = {
    # stub — replace with a map entry that references the manifest content
    always_run = "FIXME"
  }

  provisioner "local-exec" {
    command = "echo 'post-deploy hook: app=${random_pet.app_name.id} build=${random_id.build_id.hex}'"
  }
}
TFEOF

# ── outputs.tf ────────────────────────────────────────────────────────────────
cat > "$WORK/outputs.tf" << 'TFEOF'
output "app_name" {
  description = "Generated random pet name"
  value       = random_pet.app_name.id
}

output "build_id" {
  description = "Generated random build ID (hex)"
  value       = random_id.build_id.hex
}

output "manifest_content" {
  description = "Content of the deploy manifest file"
  value       = local_file.deploy_manifest.content
}

output "post_deploy_id" {
  description = "null_resource ID — non-empty means the post-deploy hook ran"
  value       = null_resource.post_deploy.id
}
TFEOF

echo ""
echo "Work directory : $WORK"
echo ""
echo "Task           : fill in the three TODOs in main.tf:"
echo "                 1. local_file content using both random outputs"
echo "                 2. null_resource triggers referencing manifest content"
echo "                 3. null_resource depends_on = [local_file.deploy_manifest]"
echo ""
echo "Prerequisites  : terraform 1.5+, internet once for provider download"
echo ""
echo "Initialize     : cd $WORK && terraform init"
echo "Plan           : terraform plan"
echo "Apply          : terraform apply -auto-approve"
echo "Verify + flag  : bash courses/course-23-terraform-iac/challenges/$SLUG/verify.sh"
