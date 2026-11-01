# Modules & Composition

> **Module 04 · Course 23** — A Terraform module is just a directory with `.tf` files. That simplicity is the point: the composition model is the same at every level. The module you call from `main.tf` and the root module running `plan` are the same construct. What changes is the surface area: modules expose a typed input/output interface that callers can rely on across environments and teams. This module covers authoring that interface, the sourcing model, composition patterns, and the traps that catch engineers who modularize too early or too abstractly.

---

## What a module is

Every Terraform configuration is a module. The config you run `terraform apply` in is the **root module**. Any directory of `.tf` files that another module calls is a **child module**.

```
root module (where you run plan/apply)
├── main.tf
├── variables.tf
├── outputs.tf
└── modules/
    ├── network/                  ← local child module
    │   ├── main.tf
    │   ├── variables.tf
    │   └── outputs.tf
    └── compute/                  ← local child module
        ├── main.tf
        ├── variables.tf
        └── outputs.tf
```

The module boundary defines:
- **What goes in** — `variable` blocks (the input interface)
- **What comes out** — `output` blocks (the output interface)
- **What stays hidden** — everything else: resource addresses, locals, intermediate values

Callers cannot access child module resources directly. They can only read what the module explicitly exports via `output`. This encapsulation is the whole value proposition: a well-authored module can change its internal resources (rename, restructure) without breaking callers, as long as the outputs remain stable.

---

## Authoring a module

A minimal but complete module for creating a local scratch directory and a configuration file:

```
modules/scratch-dir/
├── main.tf
├── variables.tf
└── outputs.tf
```

**`variables.tf`** — the input interface:

```hcl
variable "dir_path" {
  type        = string
  description = "Absolute path where the scratch directory will be created."
}

variable "app_name" {
  type        = string
  description = "Name used in generated file content."
}

variable "environment" {
  type        = string
  default     = "dev"
  description = "Environment label: dev, staging, or prod."

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}
```

**`main.tf`** — the implementation:

```hcl
locals {
  config_path = "${var.dir_path}/${var.app_name}-${var.environment}.conf"
}

resource "local_file" "config" {
  filename        = local.config_path
  content         = <<-EOT
    app_name    = ${var.app_name}
    environment = ${var.environment}
    managed_by  = terraform
  EOT
  file_permission = "0644"
}
```

**`outputs.tf`** — the output interface:

```hcl
output "config_path" {
  value       = local_file.config.filename
  description = "Absolute path of the generated config file."
}

output "config_id" {
  value       = local_file.config.id
  description = "Content hash of the generated config (SHA1, provider-assigned)."
}
```

Conventions that matter:
- `variables.tf`, `main.tf`, `outputs.tf` — the canonical split. Not enforced by Terraform, but universally expected.
- Every variable has a `description`. Every output has a `description`. Non-negotiable for shared modules.
- Validations on every variable that has a restricted value space.
- No hardcoded values that should be inputs — the test of "should this be a variable" is "would a different caller want a different value here?"

---

## Calling a module

In the root module:

```hcl
module "app_config" {
  source = "./modules/scratch-dir"   # local path

  dir_path    = "/tmp/terraform-lab"
  app_name    = "payments"
  environment = var.environment      # pass through from root
}
```

Access the child module's outputs:

```hcl
output "payments_config" {
  value = module.app_config.config_path
}

resource "local_file" "manifest" {
  filename = "/tmp/terraform-lab/manifest.txt"
  content  = "config is at ${module.app_config.config_path}\n"
}
```

The address format for module outputs: `module.<module_name>.<output_name>`. If the module is called with `for_each` or `count`, the address includes the instance key: `module.app_config["prod"].config_path`.

### Module meta-arguments

Modules support the same meta-arguments as resources:

```hcl
# Call the same module for multiple environments
module "config" {
  for_each = toset(["dev", "staging", "prod"])
  source   = "./modules/scratch-dir"

  dir_path    = "/tmp/terraform-lab/${each.key}"
  app_name    = "payments"
  environment = each.key
}

# Access a specific instance
output "prod_path" {
  value = module.config["prod"].config_path
}
```

> **`count` vs `for_each` in modules.** Prefer `for_each` over `count` for modules (same rule as resources). `count` produces instances addressed by numeric index: `module.config[0]`, `module.config[1]`. If you remove the middle item, all indices above it shift and Terraform destroys + recreates them. `for_each` with a meaningful key (environment name, region) is stable: removing "staging" only destroys `module.config["staging"]`.

---

## Versioning and sources

The `source` argument determines where Terraform fetches the module from:

### Local path

```hcl
source = "./modules/scratch-dir"      # relative to calling module
source = "../shared/modules/network"  # parent directory
```

Local modules do not need a version — they are read directly from disk at `init` time. Changes are picked up on the next `init` (or immediately if Terraform is already initialized with that path).

### Terraform Registry

```hcl
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"
}
```

Registry modules require a `version` constraint. Omitting it is an error. After `init`, the module is cached in `.terraform/modules/`. The lock file does **not** record module versions (only provider versions) — module pinning is solely controlled by the `version` argument.

### Git reference

```hcl
module "common" {
  source = "git::https://github.com/my-org/tf-modules.git//modules/common?ref=v1.4.2"
}
```

`//` separates the repo URL from the subdirectory within it. `ref=` accepts a tag, branch, or commit SHA. Use a tag or SHA for reproducibility — a branch ref points at the current HEAD of that branch, which is mutable.

```hcl
# Pinned to a tag — reproducible
source = "git::https://github.com/my-org/tf-modules.git//modules/common?ref=v1.4.2"

# Pinned to a SHA — maximally reproducible
source = "git::https://github.com/my-org/tf-modules.git//modules/common?ref=a3b4c5d6"

# Branch ref — NOT reproducible, avoid in production
source = "git::https://github.com/my-org/tf-modules.git//modules/common?ref=main"
```

---

## Composition patterns

### Layered stacks

Split infrastructure into layers with independent state, applied in order. Each layer's outputs feed into the next layer via remote state data sources:

```
┌───────────────────────┐
│   layer-1: network    │  VPC, subnets, SGs → state: s3/network.tfstate
└──────────┬────────────┘
           │ remote state read
┌──────────▼────────────┐
│   layer-2: data       │  RDS, S3, Elasticache → state: s3/data.tfstate
└──────────┬────────────┘
           │ remote state read
┌──────────▼────────────┐
│   layer-3: compute    │  ECS, Lambda, K8s → state: s3/compute.tfstate
└───────────────────────┘
```

```hcl
# layer-3/main.tf — read outputs from layer-2
data "terraform_remote_state" "data_layer" {
  backend = "s3"
  config = {
    bucket = "my-team-tfstate"
    key    = "services/data/terraform.tfstate"
    region = "us-east-1"
  }
}

resource "aws_ecs_service" "api" {
  ...
  # reference the DB endpoint exported by the data layer
  environment = [{
    name  = "DB_HOST"
    value = data.terraform_remote_state.data_layer.outputs.rds_endpoint
  }]
}
```

Layered stacks reduce blast radius: a failed apply in the compute layer doesn't touch the network layer's state. They also improve apply speed for large environments.

### Wrapper modules

A wrapper module sets opinionated defaults around a lower-level module (often a registry module) and exposes a simpler interface:

```hcl
# modules/our-s3-bucket/main.tf
# Wraps terraform-aws-modules/s3-bucket/aws with our org's required settings

module "bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 3.0"

  bucket        = var.bucket_name
  force_destroy = var.allow_destroy

  versioning = { enabled = true }   # mandatory in our org
  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm = "aws:kms"   # mandatory
      }
    }
  }

  tags = merge(local.org_tags, var.extra_tags)
}
```

Callers get a simpler interface and can't accidentally omit encryption. The module owner controls the org-wide defaults in one place.

### When to modularize

Modularize when:
- **The same pattern recurs across ≥ 3 places.** Copy-paste is the smell; the module is the fix.
- **Teams need to share infrastructure primitives** without sharing raw `.tf` files.
- **You need to instantiate the same shape multiple times** with different inputs (`for_each` over a module).
- **You want to enforce a policy** (e.g. every S3 bucket gets encryption) — a wrapper module is a better enforcement point than code review.

Do NOT modularize when:
- There is only one caller with no anticipated reuse.
- The "abstraction" adds more variables than it removes complexity.
- You are three levels deep in module nesting and the innermost module has two resources.

> **Over-abstraction is a real cost.** Every module call adds two levels of indirection: the caller reads `module.X.output` and has to trace through to `modules/X/main.tf` to understand the actual resource. A 5-resource config split into 4 modules is not better than a single well-commented `main.tf`. The heuristic: if explaining the module to a new teammate takes longer than just reading the resources directly, the module is net negative.

---

## The root module

The root module is where you run `plan` and `apply`. It is also a module — it has variables (supplied via CLI/env/tfvars), outputs (shown after apply, accessible via remote state), and locals. The conventions:

```
root/
├── main.tf          # module calls and top-level resources
├── variables.tf     # input variables (environment, region, etc.)
├── outputs.tf       # values you want visible after apply / in remote state
├── locals.tf        # computed values used across main.tf
├── providers.tf     # provider configuration
├── versions.tf      # terraform {} block with required_providers / required_version
├── backend.tf       # backend configuration (often kept separate for clarity)
└── terraform.tfvars # default values (committed); *.tfvars for env overrides
```

The split is convention, not requirement. Terraform merges all `.tf` files alphabetically. The convention exists because a 2000-line `main.tf` is harder to navigate than five focused files.

---

## Debugging Modules & Composition

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `Error: Unsupported argument` on a module call | Passing an argument the module doesn't declare as a variable | Check the module's `variables.tf`; the argument name must exactly match a `variable` block name |
| `Error: Unsupported attribute` reading a module output | Referencing an output the module doesn't declare, or typo in output name | Check the module's `outputs.tf`; confirm the output name |
| `module.X.output` returns the correct value in `plan` but is missing after apply | Output declared in child module but not re-exported in root module's `outputs.tf` | Add an `output` block in the root module: `value = module.X.that_output` |
| `path.module` resolves to the wrong directory | Using `path.module` in the root module vs inside a called module | `path.module` is always the directory of the `.tf` file that references it; `path.root` is always the root module directory. In a child module, use `path.module` for paths relative to the module's own directory |
| Removing a module call destroys all its resources unexpectedly | Expected — Terraform treats a removed `module` block as "destroy everything it manages" | Use `removed {}` block (Terraform 1.7+) or `state mv` to decouple resources from the module before removing the call |
| `Error: Module not installed` after changing `source` | `init` has not been re-run since the source change | `terraform init` — always required after any `source` change |
| Module version doesn't update despite changing `version` | `init` was run but the old version is cached in `.terraform/modules/` | `terraform init -upgrade` to force re-download |

### Diagnosing a missing output

The most common module frustration: you added an output to the child module but it's not visible in the root:

```bash
# Confirm the child module's output exists
grep -r 'output' modules/scratch-dir/outputs.tf
# output "config_path" { ... }   ← it's there

# Check if the root module re-exports it
grep 'module.app_config' outputs.tf
# (empty) ← missing

# Fix: add to root outputs.tf
# output "app_config_path" {
#   value = module.app_config.config_path
# }

terraform apply
terraform output app_config_path
```

### Diagnosing `path.module` issues

```bash
terraform plan
# Error: Invalid value for "path" parameter: no file exists at
#   "/Users/alice/.terraform/modules/abc123/templates/config.tpl"

# path.module in the called module resolves to the module's cache directory
# under .terraform/modules/, not the source directory.
# For files bundled with the module, reference them via path.module:
# templatefile("${path.module}/templates/config.tpl", {...})
# This works correctly from both local and registry sources.

# Common mistake: using path.root (the root module dir) inside a child module
# to reference a file that lives next to the child module's .tf files.
# path.root is ONLY correct for files in the root module directory.
```

> **War story.** A team built a "golden" internal module for their ECS service definition and published it to their private Terraform Registry. The module had four outputs: `service_arn`, `task_definition_arn`, `lb_target_group_arn`, and `security_group_id`. Six months later a new team used the module, needed the security group ID in their WAF config, and noticed `module.ecs_service.security_group_id` worked fine in their staging root. They shipped to production, and the production root module gave `Error: Unsupported attribute: This object does not have an attribute named "security_group_id"`. The module had three published versions and `security_group_id` was only added in `v1.3.0`. The production stack was pinned to `~> 1.2` and never got the update. The caller was referencing an output that didn't exist in the version they had pinned. The fix was a one-line version bump — `version = "~> 1.3"` — and `terraform init -upgrade`. The lesson: when you can't see an output you expect from a registry module, check the version you're running, not just the latest docs.

---

## Checkpoint

You're ready for the module challenges when you can, without looking anything up:

1. Describe the interface contract a module exposes to its callers (what goes in, what comes out, what's hidden).
2. Write a complete three-file child module (`variables.tf`, `main.tf`, `outputs.tf`) for a `local_file` resource with two required inputs and one output.
3. Explain the difference between `path.module` and `path.root` and give a scenario where using the wrong one fails silently.
4. Configure a module call with `for_each` over a set of environment names and show how to access an output for a specific instance.
5. State three situations where modularization pays off and two where it is net negative.
6. Pin a Git-sourced module to a specific commit SHA and explain why a branch ref is not reproducible.
7. Diagnose and fix the case where a child module output exists but is invisible to the root module.
8. Explain what happens to a module's managed resources when you remove the `module {}` call from `.tf` files and run `apply`.
9. Describe the "wrapper module" pattern and name one concrete benefit it provides over direct use of a community module.

➡ You've completed the four core modules. Move on to the challenges to apply state management, module composition, and local-provider patterns in hands-on verifier labs.
