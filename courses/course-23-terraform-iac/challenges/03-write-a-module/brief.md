# Write a Reusable Module

The ticket reads: *"We have three environments. Every one of them copies the same `local_file` HCL. One was updated last week, the others weren't. We now have config drift between dev, staging, and prod and nobody knows what changed. Refactor into a module."*

Copy-pasting infrastructure is the same failure mode as copy-pasting application code: it works fine until the third environment diverges at 2am on a Friday. A Terraform child module is the unit of reuse: define the resource once, expose inputs and outputs, call it from everywhere.

## Context

`setup.sh` plants a starter structure in your work directory:

```
~/.kube-dojo-work/03-write-a-module/
├── main.tf                      # root config — module call stub
├── outputs.tf                   # root output stub
└── modules/
    └── filemaker/
        ├── variables.tf         # module input variable stubs
        ├── main.tf              # module resource stub
        └── outputs.tf           # module output stub
```

## Prerequisites

Terraform 1.5+ on your `PATH`:

```bash
terraform version
```

## Mission

Implement all five files so that after `terraform apply` from the root:

1. **`modules/filemaker/variables.tf`** — declare two variables:
   - `output_dir` (string, no default) — absolute path of the directory to create the file in
   - `content` (string, default `"Module output.\n"`) — content to write
2. **`modules/filemaker/main.tf`** — declare a `local_file` resource named `"out"` that creates `${var.output_dir}/message.txt` with `var.content`
3. **`modules/filemaker/outputs.tf`** — expose the created file path as output `"file_path"`
4. **`main.tf`** (root) — call `module "filemaker"` with `source = "./modules/filemaker"`, passing `output_dir = "${path.module}/output"` and `content = "Hello from the module!\n"`
5. **`outputs.tf`** (root) — declare output `"created_path"` wired from `module.filemaker.file_path`

### What verify checks

| Check | Expected |
|-------|----------|
| `terraform apply` | succeeds |
| File exists | `~/.kube-dojo-work/03-write-a-module/output/message.txt` |
| File content | `Hello from the module!` |
| `terraform output -raw created_path` | absolute path of the created file |

## Why this matters

Modules are how Terraform scales beyond a single team or a single environment. The public Terraform registry is entirely composed of modules — when you `module "vpc" { source = "terraform-aws-modules/vpc/aws" }` you're calling the same mechanism you're building here. Understanding the module interface (variables in, outputs out, resources inside) is what lets you read and trust third-party modules instead of copy-pasting their contents.

The key insight: a module's outputs are its API contract. A caller that references `module.filemaker.file_path` is depending on that name being stable — renaming the output is a breaking change, exactly like renaming a public function.

### Module call syntax

```hcl
module "label" {
  source      = "./path/to/module"    # local path, or registry address
  input_name  = value                 # one argument per declared variable
}
```

Reference the module's outputs with `module.<label>.<output_name>`.

## Verify

```bash
bash courses/course-23-terraform-iac/challenges/03-write-a-module/verify.sh
```

All checks green → flag printed.
