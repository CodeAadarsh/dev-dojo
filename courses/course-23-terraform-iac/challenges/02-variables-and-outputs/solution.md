# Solution — Variables and Outputs

Three files to implement. Copy each into your work directory.

### `variables.tf`

```hcl
variable "output_filename" {
  type        = string
  default     = "greeting.txt"
  description = "Name of the output file. Must end with .txt."

  validation {
    condition     = endswith(var.output_filename, ".txt")
    error_message = "output_filename must end with .txt — binary filenames are not accepted."
  }
}

variable "output_content" {
  type        = string
  default     = "Hello, variables!\n"
  description = "Content to write into the output file."
}
```

### `main.tf`

```hcl
terraform {
  required_providers {
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

resource "local_file" "doc" {
  filename = "${path.module}/output/${var.output_filename}"
  content  = var.output_content
}
```

### `outputs.tf`

```hcl
output "result_path" {
  value       = local_file.doc.filename
  description = "Absolute path of the file created by this configuration."
}
```

## Why each piece is required

**`type = string` on variables** — Terraform coerces inputs at the CLI boundary. Declaring `type` means passing `-var output_content=42` is accepted (coerced to `"42"`) but passing a list or map is rejected with a type error before any plan runs. Always declare the type; never rely on Terraform's implicit coercion.

**`endswith(var.output_filename, ".txt")` in the validation condition** — `endswith` is a first-class Terraform built-in (available since 1.3). The condition is a boolean expression evaluated at plan time in the variable's own scope — you can reference `var.<this_variable>` but nothing else (no other variables, no data sources). If the condition is `false`, Terraform prints `error_message` and exits 1 before touching any infrastructure.

**`local_file.doc.filename` as the output value** — this is the *resource attribute*, not the *input argument*. They happen to have the same value here, but reading from the attribute means: "whatever path Terraform actually created the file at after apply." This is the correct pattern — outputs should reference resource attributes, not input variables, so the value is guaranteed to reflect post-apply reality.

**`description` on every variable and output** — not required for the verifier, but required for any publishable module. `terraform-docs` and the Terraform registry both surface these descriptions, and callers won't use a module they can't understand from its interface alone.

## Apply and verify

```bash
cd ~/.kube-dojo-work/02-variables-and-outputs
terraform init && terraform apply -auto-approve
terraform output result_path          # see the output
terraform apply -auto-approve -var "output_content=custom\n"   # override a variable
bash courses/course-23-terraform-iac/challenges/02-variables-and-outputs/verify.sh
```

## Attacker's view

An input variable with no validation is a trust boundary with no guard. In production Terraform, this matters for things like bucket names (must match AWS naming rules), CIDR blocks (must be valid CIDR notation), and — critically — IAM policy JSON (must be syntactically valid before you hand it to the IAM API). A malformed value that passes variable parsing but fails the API call leaves your state half-applied: some resources created, others not, with a tfstate that no longer matches reality. The `validation` block is cheap insurance against that class of failure.
