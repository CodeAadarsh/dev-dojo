# Provisioners, Secrets & Good Practice

> **Module 07 · Course 23** — This module covers the sharp edges: provisioners (why they exist and why you almost always want something else), the secret-in-state problem (it's worse than you think), testing Terraform code, and the practices checklist that separates a codebase you can trust from one you inherited and fear.

You've written real Terraform by now. This module is the difference between code that *works* and code that's *maintainable and safe at 2am during an incident*.

---

## Why provisioners are a last resort

Provisioners run shell commands or file copies on a machine — either the machine Terraform runs on (`local-exec`) or a remote machine (`remote-exec`). They were added to Terraform early, before cloud providers built rich APIs. Today, almost every task that provisioners handle has a better, provider-native solution.

The core problem: **provisioners are imperative, not declarative**. Terraform cannot model their output in the plan. If a provisioner fails mid-apply, Terraform marks the resource as "tainted" (needing replacement) but the partial side effects have already occurred. The next apply may fail, succeed with a different result, or silently skip the provisioner because the resource was "just recreated." This makes provisioners non-idempotent by default, which is the property Terraform's entire model is built on.

```
Terraform model:         plan → execute → state updated → idempotent
Provisioner model:       plan (opaque) → execute → state might be updated → ????
```

The exact wording from HashiCorp's own documentation: *"Provisioners are a last resort."*

### What to use instead

| Provisioner use case | Better alternative |
|----------------------|-------------------|
| Bootstrap a VM with packages | `cloud-init` / `user_data` on the instance resource |
| Copy a config file to a VM | Bake it into the image (Packer), or use `cloud-init` |
| Run a local script after apply | `null_resource` + `local-exec` (still a provisioner, but scoped) |
| Register a DNS record after a VM is created | Use the DNS provider resource — it's a real resource with plan output |
| Trigger an external API after apply | `terraform_data` with a `local-exec` provisioner, or a dedicated provider |

The pattern: if a cloud provider has a native API for the thing you want to do, there is almost certainly a Terraform provider resource for it. Use that. It has plan output, it has state, and it can be re-applied cleanly.

---

## null_resource and triggers

When you genuinely need to run a local command as part of an apply — and no provider resource fits — `null_resource` (from `hashicorp/null`) is the tool. It's a resource with no real infrastructure behind it, but it participates in the Terraform lifecycle and can run provisioners.

```hcl
terraform {
  required_providers {
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }
}

resource "local_file" "config" {
  filename = "${path.module}/output/config.json"
  content  = jsonencode({ environment = var.env, version = var.app_version })
}

resource "null_resource" "deploy_notify" {
  triggers = {
    # Re-run the provisioner whenever the config file content changes
    config_hash = local_file.config.content
  }

  provisioner "local-exec" {
    command = "echo 'Config updated for env=${var.env}, version=${var.app_version}' >> ${path.module}/output/deploy.log"
  }
}
```

`triggers` is a map of strings. Whenever any trigger value changes between applies, Terraform destroys and recreates the `null_resource`, which re-runs the provisioner. If no triggers change, the provisioner does not re-run.

Common trigger patterns:
- `triggers = { hash = sha256(file("script.sh")) }` — re-run when a script changes
- `triggers = { id = resource.name.id }` — re-run when the upstream resource is replaced
- `triggers = { always = timestamp() }` — re-run on every apply (use sparingly; breaks idempotency)

### terraform_data — the null_resource successor

In Terraform 1.4+, `terraform_data` is the built-in replacement for `null_resource`. No provider required.

```hcl
resource "terraform_data" "bootstrap" {
  triggers_replace = [local_file.config.content]

  provisioner "local-exec" {
    command = "echo 'bootstrapped' >> ${path.module}/output/deploy.log"
  }
}
```

`triggers_replace` accepts a list (any type) instead of a map of strings — cleaner syntax.

---

## Moving logic to real providers

The canonical alternative to provisioners. When you find yourself writing a `local-exec` to call an API or manage a resource, ask: "Is there a Terraform provider for this?"

Examples of tasks that look like they need provisioners but don't:

```hcl
# Instead of: null_resource with local-exec to create a file
# Use: local_file resource
resource "local_file" "rendered" {
  filename = "${path.module}/output/app.conf"
  content  = templatefile("${path.module}/templates/app.conf.tpl", { port = var.port })
}

# Instead of: null_resource with local-exec to generate a random string
# Use: random_id or random_password resource
resource "random_password" "db" {
  length  = 24
  special = true
}

# Instead of: local-exec curl to hit a webhook
# Use: http provider or a dedicated provider for the service
```

The `local`, `random`, `null`, `http`, `tls`, and `archive` providers cover a wide range of "glue" tasks without provisioners. Check https://registry.terraform.io before reaching for `local-exec`.

---

## Handling secrets

This is the area where teams cause the most damage without realising it immediately.

### The state file is a secrets store — whether you want it to be or not

Every resource attribute Terraform manages is written to state. This includes:
- Database passwords
- API keys
- Private key material
- OAuth tokens

If you create a `random_password` resource, its `result` attribute is in state in plaintext. If your state is stored locally as `terraform.tfstate`, it is an unencrypted JSON file readable by anyone with filesystem access. If it is stored in a remote backend (S3, Terraform Cloud), access controls on that backend are now your security perimeter.

```bash
# Local state — check what's in there
cat terraform.tfstate | grep -A2 '"result"'    # plaintext passwords visible
```

**Rules:**
1. Never store state locally in production. Use a remote backend with encryption at rest and access controls.
2. For S3 backends: enable server-side encryption + bucket versioning + MFA delete + restrict IAM access to the state bucket.
3. Mark sensitive outputs: `sensitive = true` hides values from terminal output but does **not** remove them from state.

```hcl
output "db_password" {
  value     = random_password.db.result
  sensitive = true    # suppresses terminal output; NOT a security control on state
}
```

### Never put secrets in .tf files or tfvars

```hcl
# Wrong — committed to git, plaintext
variable "db_password" {
  default = "supersecret123"
}
```

```hcl
# Right — no default; must be supplied at runtime
variable "db_password" {
  type      = string
  sensitive = true
}
```

Supply at runtime via environment variable:

```bash
export TF_VAR_db_password="$(vault read -field=password secret/db)"
terraform apply
```

Or pass via `-var`:

```bash
terraform apply -var="db_password=$(vault read -field=password secret/db)"
```

### Using vault or secrets managers

For production workloads, don't pass secrets via environment variables at CI level either — use a secrets provider integration:

```hcl
# hashicorp/vault provider — reads from Vault at plan time
data "vault_generic_secret" "db" {
  path = "secret/myapp/db"
}

resource "local_file" "db_config" {
  filename = "${path.module}/output/db.conf"
  content  = "password=${data.vault_generic_secret.db.data["password"]}\n"
  # Note: this still writes the secret to local state — encrypt your state backend
}
```

---

## Tainting and forced replacement

`terraform taint` (deprecated since 1.0) marked a resource for destruction and recreation on the next apply. Its replacement is `-replace`:

```bash
# Force replace a specific resource in the next apply
terraform plan -replace=local_file.config
terraform apply -replace=local_file.config

# Multiple resources
terraform apply -replace=local_file.config -replace=random_id.token
```

`-replace` is the right tool when a resource is in an inconsistent state that Terraform's plan doesn't detect — for example, a VM whose OS is corrupted but whose API state still reports "running." The plan with `-replace` will show a `-/+` (destroy and recreate) for that resource.

Do not use `-replace` as a routine operation. If you find yourself regularly replacing the same resource, that's a signal that something in the resource lifecycle or its inputs is non-deterministic.

---

## Testing Terraform

### terraform test (1.6+)

`terraform test` runs `.tftest.hcl` files. Each test creates real infra (using the configured providers), asserts conditions, and then destroys everything after the test run.

```hcl
# tests/outputs.tftest.hcl
run "check_config_file_created" {
  command = apply

  assert {
    condition     = fileexists("${path.module}/output/config.txt")
    error_message = "Config file was not created"
  }

  assert {
    condition     = local_file.config.content != ""
    error_message = "Config file content is empty"
  }
}

run "check_random_id_length" {
  command = plan

  assert {
    condition     = length(random_id.token.hex) == 16
    error_message = "Expected 8-byte (16-char hex) random ID"
  }
}
```

```bash
terraform test                    # run all .tftest.hcl files
terraform test -filter=tests/outputs.tftest.hcl
```

`command = plan` asserts against the plan without applying; `command = apply` creates real infra, runs asserts, destroys.

### Terratest (Go-based)

Terratest is a Go library that wraps Terraform CLI calls and lets you write integration tests with the full power of Go:

```go
// test/terraform_test.go
package test

import (
    "testing"
    "github.com/gruntwork-io/terratest/modules/terraform"
    "github.com/stretchr/testify/assert"
)

func TestOutputsExist(t *testing.T) {
    opts := &terraform.Options{
        TerraformDir: "../",
        Vars: map[string]interface{}{
            "env": "test",
        },
    }
    defer terraform.Destroy(t, opts)
    terraform.InitAndApply(t, opts)

    configFile := terraform.Output(t, opts, "config_file_path")
    assert.Contains(t, configFile, "test-config")
}
```

Terratest is worth the investment when:
- You have module libraries shared across teams
- You need to test multi-resource interactions (e.g. a module that provisions a VPC + subnet + security group, and you need to verify the subnet is actually inside the VPC CIDR)
- You want property-based or randomised test inputs

For single-module testing, `terraform test` is sufficient. Reach for Terratest when you need a real programming language to express the assertion logic.

---

## Debugging Provisioners & Secrets

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Apply succeeds but provisioner side effects are missing | Provisioner ran on a previous apply (resource wasn't recreated) and triggers didn't change | Add or update a `triggers` entry to force re-execution; or use `terraform apply -replace=null_resource.name` |
| `Error: local-exec provisioner error` mid-apply; resource is now tainted | The shell command failed (non-zero exit); Terraform marks the resource tainted | Fix the shell command, then `terraform apply` again — the tainted resource will be destroyed and recreated, re-running the provisioner |
| Provisioner runs successfully on first apply but fails on the second (non-idempotent) | The command isn't idempotent (e.g. `mkdir` on a path that already exists) | Make the command idempotent (`mkdir -p`, `upsert` semantics) or add a guard: `if [ ! -f file ]; then ...; fi` |
| Plaintext secret visible in `terraform state show` | Sensitive variable or resource attribute written to state | Expected — state always stores attribute values. Mitigate: use a remote backend with encryption at rest + access controls; mark outputs `sensitive = true` for terminal suppression |
| `terraform plan` shows a secret value in the diff output | Attribute is not marked `sensitive` in the provider schema | Wrap the resource in a `sensitive()` function call for outputs; for variables, set `sensitive = true`; for provider resources you don't control, use `nonsensitive()` only when you're certain it's safe |
| Provisioner failure left half-created resources that are now orphaned | Provisioner created external state Terraform doesn't track (files, DNS records, DB rows) | Manual cleanup required; document the cleanup procedure; this is the primary reason provisioners are a last resort |

> **War story.** A teammate added a `local-exec` provisioner to a `null_resource` that ran a Python script to register a service in an internal catalog. The script was idempotent on success but failed with exit code 1 if the service already existed (a different registration had been done manually the week before). First apply after a state refresh: Terraform saw the `null_resource` as needing recreation (a trigger had changed), ran the provisioner, got exit code 1, and marked the resource tainted. Every subsequent apply then tried to destroy and recreate the `null_resource` — which destroyed it, ran the provisioner again, got exit code 1, tainted it again. The configuration was effectively stuck in a loop: every apply changed the state but never converged. The fix was five minutes: make the Python script exit 0 if the service already existed. The lesson: provisioner exit codes are the only signal Terraform has. A non-zero exit taints the resource regardless of whether the side effect you cared about already happened correctly. Always make provisioner commands idempotent and exit 0 when the desired state is already true.

---

## Practices Checklist

Use this as a pre-merge checklist for any Terraform change:

### Code

- [ ] `terraform fmt -check` passes (no formatting diffs)
- [ ] `terraform validate` passes (no schema errors)
- [ ] No hardcoded secret values in `.tf` or `.tfvars` files
- [ ] Sensitive variables declared with `sensitive = true`
- [ ] All provider version constraints are pinned (`~> 1.2`, not `>= 1`)
- [ ] `.terraform.lock.hcl` is committed to version control
- [ ] `for_each` used in preference to `count` for named resources
- [ ] No `count` on lists of named things (index churn risk)

### State & Secrets

- [ ] State is stored in a remote backend with encryption at rest (not local for shared infra)
- [ ] State backend access is restricted to CI and a named ops group
- [ ] No plaintext secrets in any committed file
- [ ] Secret rotation does not require a `terraform destroy`

### Lifecycle

- [ ] `terraform plan -out=tfplan` + `terraform apply tfplan` is the CI flow (not interactive apply)
- [ ] `plan -destroy` has been reviewed before any `destroy` to production
- [ ] Workspace / directory is confirmed correct before every apply
- [ ] `-target` is not used in routine CI applies; if used, a full plan follows immediately

### Maintainability

- [ ] Modules have a `README` with input/output descriptions (or use `terraform-docs`)
- [ ] `moved` blocks are used instead of `terraform state mv` when refactoring resource addresses
- [ ] Provisioners are justified in a comment with "why no provider resource exists for this"
- [ ] At least a `terraform test` smoke test covers the module's critical outputs

### Debugging aids

- [ ] `terraform plan` output is saved as a CI artifact or PR comment for audit
- [ ] `terraform show tfplan` is available for post-mortem (review what was applied)

---

## Checkpoint

You're ready for the provisioners module when you can, without looking anything up:

1. Name two concrete problems with using `local-exec` provisioners for idempotency, and state what happens when a provisioner fails mid-apply.
2. Write a `null_resource` (or `terraform_data`) with a trigger that re-runs a local-exec when a file's content changes.
3. State why `sensitive = true` on an output is not a security control, and what actually controls who can read the secret from state.
4. Demonstrate the correct way to supply a secret to a Terraform run at CI time — without committing the value to any file.
5. Write the one-line command to force replacement of a specific resource (the non-deprecated form).
6. Write a minimal `terraform test` block that asserts a file exists after apply.
7. Reproduce the practices checklist from memory for the five most important items in each of: Code, State & Secrets, and Lifecycle.
8. Explain the non-idempotent provisioner loop problem and state the two properties a provisioner command must have to avoid it.

➡ You've completed the core Terraform IaC module sequence. The challenge set applies every concept from Modules 01–07 against live `terraform` runs using local providers — no cloud account, no credentials, all signal.
