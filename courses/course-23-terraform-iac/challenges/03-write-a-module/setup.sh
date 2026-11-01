#!/usr/bin/env bash
# Plants the "Write a Reusable Module" starter into the work directory.
# Idempotent — safe to re-run.
set -euo pipefail

SLUG="03-write-a-module"
WORK="$HOME/.kube-dojo-work/$SLUG"
mkdir -p "$WORK/output"
mkdir -p "$WORK/modules/filemaker"

# ── root: main.tf ─────────────────────────────────────────────────────────────
cat > "$WORK/main.tf" << 'HCLEOF'
terraform {
  required_providers {
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

# Call the filemaker child module.
# source  = "./modules/filemaker"
# Pass:
#   output_dir = "${path.module}/output"   (absolute path; module creates a file here)
#   content    = "Hello from the module!\n"
module "filemaker" {
  source = "./modules/filemaker"
  # TODO: add input arguments
}
HCLEOF

# ── root: outputs.tf ──────────────────────────────────────────────────────────
cat > "$WORK/outputs.tf" << 'HCLEOF'
# Wire the module's file_path output to a root output named "created_path".
# Syntax: module.<label>.<output_name>
output "created_path" {
  value = ""  # <- reference module.filemaker.<module-output-name>
}
HCLEOF

# ── module: variables.tf ──────────────────────────────────────────────────────
cat > "$WORK/modules/filemaker/variables.tf" << 'HCLEOF'
# Declare two input variables:
#
# 1. output_dir (string, no default)
#    Description: absolute directory path where the file will be created.
#    The resource will create: "${var.output_dir}/message.txt"
#
# 2. content (string, default "Module output.\n")
#    Description: text content to write into the file.
HCLEOF

# ── module: main.tf ───────────────────────────────────────────────────────────
cat > "$WORK/modules/filemaker/main.tf" << 'HCLEOF'
# Declare a local_file resource named "out".
# filename = "${var.output_dir}/message.txt"
# content  = var.content
HCLEOF

# ── module: outputs.tf ────────────────────────────────────────────────────────
cat > "$WORK/modules/filemaker/outputs.tf" << 'HCLEOF'
# Expose the absolute path of the created file as output "file_path".
# value = local_file.out.filename
HCLEOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : implement all five files (see brief.md for exact"
echo "                 variable names, output names, and content)."
echo
echo "Structure      :"
echo "  $WORK/main.tf"
echo "  $WORK/outputs.tf"
echo "  $WORK/modules/filemaker/variables.tf"
echo "  $WORK/modules/filemaker/main.tf"
echo "  $WORK/modules/filemaker/outputs.tf"
echo
echo "Prerequisites  : terraform 1.5+"
echo
echo "When ready     : bash courses/course-23-terraform-iac/challenges/03-write-a-module/verify.sh"
