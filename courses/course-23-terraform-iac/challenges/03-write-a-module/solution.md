# Solution — Write a Reusable Module

Five files to implement. Copy each into its correct location.

### `modules/filemaker/variables.tf`

```hcl
variable "output_dir" {
  type        = string
  description = "Absolute directory path where the file will be created."
}

variable "content" {
  type        = string
  default     = "Module output.\n"
  description = "Text content to write into the file."
}
```

### `modules/filemaker/main.tf`

```hcl
resource "local_file" "out" {
  filename = "${var.output_dir}/message.txt"
  content  = var.content
}
```

### `modules/filemaker/outputs.tf`

```hcl
output "file_path" {
  value       = local_file.out.filename
  description = "Absolute path of the file created by this module."
}
```

### `main.tf` (root)

```hcl
terraform {
  required_providers {
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

module "filemaker" {
  source     = "./modules/filemaker"
  output_dir = "${path.module}/output"
  content    = "Hello from the module!\n"
}
```

### `outputs.tf` (root)

```hcl
output "created_path" {
  value       = module.filemaker.file_path
  description = "Absolute path of the file created by the filemaker module."
}
```

## Why each piece is required

**Module directory structure** — Terraform treats any directory that contains `.tf` files as a module. The `source = "./modules/filemaker"` path is relative to the root module, so it must match exactly. A mistyped path fails at `terraform init` with `Module not found`.

**`output_dir` variable with no default** — a variable without a `default` is *required*. The caller must supply it. This is intentional: the module shouldn't guess where to create files. Making required inputs required (no default) is better than defaulting to a path that may not exist on the caller's machine.

**`local_file.out.filename` in the module output** — the module's output is its contract with callers. The root configuration references it as `module.filemaker.file_path`. If you rename this output in the module, every caller breaks. Treat module outputs like a public API; version them accordingly.

**`module.filemaker.file_path` in the root output** — this is the *output chaining* pattern: module output flows through the root output to the `terraform output` command. The value Terraform stores is the evaluated string — the absolute path — not a reference. This means `terraform output -raw created_path` prints the actual filesystem path, not a Terraform expression.

**`terraform init -upgrade` re-required after adding a module** — when you add a `module` block with a local source for the first time, `terraform init` processes it and writes the module path into `.terraform/modules/modules.json`. If you forget to re-run `init` after adding the block, `terraform plan` errors with `Module not installed`. This is a common mistake; the verifier runs `init` with `-upgrade` to catch it cleanly.

## Apply and verify

```bash
cd ~/.kube-dojo-work/03-write-a-module
terraform init         # required after adding a module block
terraform plan         # see the resource Terraform will create inside the module
terraform apply -auto-approve
terraform output       # see created_path
terraform show         # see full state including the module resource
bash courses/course-23-terraform-iac/challenges/03-write-a-module/verify.sh
```

## Attacker's view / hardening preview

When you use a public registry module (`source = "terraform-aws-modules/vpc/aws"`), you're executing third-party code in your Terraform run with full access to your provider credentials. Pinning the exact version (`version = "5.8.1"`) and committing `.terraform.lock.hcl` limits the blast radius of a supply-chain compromise — a malicious update can't be pulled without a deliberate `terraform init -upgrade`. Treat public modules exactly like third-party library dependencies: pin, review diffs on update, never pull from a mutable `latest`.
