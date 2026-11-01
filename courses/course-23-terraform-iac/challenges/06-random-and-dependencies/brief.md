# Random Values and Explicit Dependencies

A deploy pipeline generates a unique name and a build ID for every release, writes them into a manifest, and then runs a "post-deploy hook" — a shell command that registers the build. The hook must only run *after* the manifest is written. Someone merged a change that broke the ordering: the hook fires before the manifest is current, registers a stale build ID, and the tracking dashboard is now permanently confused.

Your job: wire the dependency graph correctly so Terraform guarantees the ordering, and make the hook re-fire whenever the manifest content changes.

## Context

`setup.sh` plants a starter project in your work directory:

```
~/.kube-dojo-work/06-random-and-dependencies/
├── main.tf      # random_pet, random_id, local_file, null_resource — stubs to fill
└── outputs.tf   # app_name, build_id, manifest_content, post_deploy_id outputs
```

## Prerequisites

```bash
cd ~/.kube-dojo-work/06-random-and-dependencies
terraform init
```

Terraform 1.5+ and internet once for provider download (hashicorp/random ~3.5, hashicorp/null ~3.2, hashicorp/local ~2.4).

## The three resources and why they exist

**`random_pet` + `random_id`** generate stable values per workspace. "Stable" means they are generated once, written to state, and do not change on subsequent plans unless you `taint` or `terraform apply -replace` them. This is how you name ephemeral environments (staging-funny-horse-4a2f) without hard-coding.

**`local_file`** writes the generated values into a manifest on disk. It has an *implicit* dependency on the random resources because it interpolates their outputs — Terraform resolves this automatically via the expression graph.

**`null_resource`** models a side-effect (shell command, webhook call, API trigger) that has no real resource behind it. It runs its `provisioner "local-exec"` when it is created **or when its `triggers` map changes**. Triggers are the mechanism for "re-run this whenever X changes."

```hcl
resource "null_resource" "post_deploy" {
  triggers = {
    manifest_hash = local_file.deploy_manifest.content
  }
  depends_on = [local_file.deploy_manifest]
  provisioner "local-exec" {
    command = "echo 'post-deploy hook fired for build ${random_id.build_id.hex}'"
  }
}
```

`triggers` causes a recreate (destroy + create) of the `null_resource` whenever the map value changes. `depends_on` enforces that the `local_file` is fully written before the `null_resource` is created, even though the expression in `triggers` already creates an implicit edge. The explicit `depends_on` is documentation and a guard against future refactors that might break the implicit edge.

## Mission

Fill in the stubs in `main.tf`:

1. **`local_file.deploy_manifest`** — set `filename` to `"${path.module}/deploy-manifest.txt"` and `content` to include both `random_pet.app_name.id` and `random_id.build_id.hex`.
2. **`null_resource.post_deploy`** — set `triggers` to a map containing `local_file.deploy_manifest.content`, and add `depends_on = [local_file.deploy_manifest]`. The starter includes a `provisioner "local-exec"` block — keep it.

The `verify.sh` checks:

1. `terraform apply` exits 0.
2. `deploy-manifest.txt` exists and contains the `app_name` output value (the random pet name).
3. `deploy-manifest.txt` contains the `build_id` output value (the hex string).
4. The `post_deploy_id` output is non-empty (null_resource was created).

## Why explicit depends_on is not always redundant

Terraform builds its dependency graph from **expression references** in the config. If you write `content = local_file.deploy_manifest.content` in `triggers`, Terraform already knows the `null_resource` depends on the `local_file`. But there are cases where the dependency is not captured by an expression:

- The `provisioner "local-exec"` command reads a file that the `local_file` writes, but the command is a plain string (`"cat deploy-manifest.txt"`) with no HCL reference — Terraform can't see the dependency.
- A module output is consumed by a provisioner through an environment variable rather than an interpolation.

In those cases, `depends_on` is the only way to express the ordering. The discipline of adding it even when it is technically redundant makes the graph explicit and reviewable.

## Verify

```bash
bash courses/course-23-terraform-iac/challenges/06-random-and-dependencies/verify.sh
```

All checks green → flag printed.
