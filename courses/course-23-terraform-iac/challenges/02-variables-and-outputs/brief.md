# Variables and Outputs

During a code review a senior engineer leaves this comment: *"These hardcoded paths and strings are fine for a spike but will make this module useless to anyone else. Add variables with sensible defaults and a validation rule so callers can't accidentally pass in a binary filename."*

That's the whole challenge: replace hardcoded values with parameterized inputs, guard them with a validation rule, and expose what the module produced via an output.

## Context

`setup.sh` plants a starter configuration in your work directory:

```
~/.kube-dojo-work/02-variables-and-outputs/
├── main.tf          # terraform block + local_file resource stub
├── variables.tf     # two variable stubs to fill in
├── outputs.tf       # one output stub to fill in
└── output/          # Terraform will create the file here
```

## Prerequisites

Terraform 1.5+ on your `PATH`:

```bash
terraform version
```

## Mission

Implement `variables.tf`, `outputs.tf`, and the `local_file` resource body in `main.tf` so that:

1. Variable `output_filename` — type `string`, default `"greeting.txt"`, validation rule that rejects any filename that does not end with `.txt`.
2. Variable `output_content` — type `string`, default `"Hello, variables!\n"`.
3. The `local_file` resource creates `output/<output_filename>` using `${path.module}/output/${var.output_filename}` as the path and `var.output_content` as the content.
4. Output `result_path` — the `filename` attribute of the created resource (the absolute path on disk).

### What verify checks

| Check | Expected |
|-------|----------|
| `terraform apply` with defaults | succeeds |
| File exists | `~/.kube-dojo-work/02-variables-and-outputs/output/greeting.txt` |
| File content | `Hello, variables!` |
| `terraform output -raw result_path` | absolute path of the created file |
| Validation: `terraform plan -var output_filename=evil.csv` | exits non-zero (validation rejects non-.txt) |

## Why this matters

Every real Terraform module exposes variables for the same reason every function takes parameters: it lets the same logic run in dev, staging, and prod without forking the code. The discipline of adding types and validation early is what separates a module you can publish from one that only works under one set of assumptions.

The `output` block is the module's return value. Without it, callers can't chain resources — they can't use the file path to set permissions on the file, pass it to another resource, or surface it in `terraform show`. Outputs are not optional once you build anything larger than a spike.

### Validation block syntax

```hcl
variable "output_filename" {
  type    = string
  default = "..."
  validation {
    condition     = <boolean expression using var.output_filename>
    error_message = "Human-readable rejection reason."
  }
}
```

Terraform evaluates the condition at plan time. If it is `false`, apply never runs — the error is surfaced as a first-class validation error, not a cryptic provider crash.

## Verify

```bash
bash courses/course-23-terraform-iac/challenges/02-variables-and-outputs/verify.sh
```

All five checks green → flag printed.
