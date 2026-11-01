#!/usr/bin/env bash
# Plants the "Variables and Outputs" starter into the work directory.
# Idempotent — safe to re-run.
set -euo pipefail

SLUG="02-variables-and-outputs"
WORK="$HOME/.kube-dojo-work/$SLUG"
mkdir -p "$WORK/output"

# ── main.tf ──────────────────────────────────────────────────────────────────
cat > "$WORK/main.tf" << 'HCLEOF'
terraform {
  required_providers {
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

# Use var.output_filename and var.output_content here.
# filename should be "${path.module}/output/${var.output_filename}"
resource "local_file" "doc" {
  filename = ""  # <- use the variable
  content  = ""  # <- use the variable
}
HCLEOF

# ── variables.tf ─────────────────────────────────────────────────────────────
cat > "$WORK/variables.tf" << 'HCLEOF'
# Declare two input variables:
#
# 1. output_filename
#    type:    string
#    default: "greeting.txt"
#    validation: condition must ensure the filename ends with ".txt"
#                use the built-in endswith() function (Terraform >= 1.3)
#
# 2. output_content
#    type:    string
#    default: "Hello, variables!\n"
HCLEOF

# ── outputs.tf ───────────────────────────────────────────────────────────────
cat > "$WORK/outputs.tf" << 'HCLEOF'
# Declare one output named "result_path".
# Its value should be the filename attribute of the local_file resource:
#   local_file.doc.filename
HCLEOF

echo
echo "Work directory : $WORK"
echo
echo "Task           : implement variables.tf, outputs.tf, and the"
echo "                 resource body in main.tf so all five verify"
echo "                 checks pass (see brief.md for exact conditions)."
echo
echo "Prerequisites  : terraform 1.5+"
echo
echo "When ready     : bash courses/course-23-terraform-iac/challenges/02-variables-and-outputs/verify.sh"
