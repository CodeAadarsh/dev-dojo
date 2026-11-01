# Solution — Random Values and Explicit Dependencies

Three edits to `main.tf`: fix `local_file.deploy_manifest` content, fix `null_resource.post_deploy` triggers, and add `depends_on`.

```hcl
resource "local_file" "deploy_manifest" {
  filename = "${path.module}/deploy-manifest.txt"
  content  = "app_name = ${random_pet.app_name.id}\nbuild_id = ${random_id.build_id.hex}\n"
}

resource "null_resource" "post_deploy" {
  triggers = {
    manifest_hash = local_file.deploy_manifest.content
  }
  depends_on = [local_file.deploy_manifest]

  provisioner "local-exec" {
    command = "echo 'post-deploy hook: app=${random_pet.app_name.id} build=${random_id.build_id.hex}'"
  }
}
```

`outputs.tf` and the random resource blocks need no changes.

## Why each piece is required

**`random_pet.app_name.id` and `random_id.build_id.hex` in the content.**
Interpolating the outputs of the random resources creates *implicit* dependencies in the Terraform graph: Terraform knows it must create `random_pet` and `random_id` before it can evaluate the `local_file` content. The generated values are stable — they are stored in state after the first `apply` and do not regenerate on subsequent plans unless you run `terraform apply -replace=random_pet.app_name`.

**`triggers = { manifest_hash = local_file.deploy_manifest.content }`.**
`null_resource` has no real infrastructure backing it. Without triggers, it is created once and never re-runs. Setting a trigger to the manifest content causes Terraform to hash the map and detect changes: if the manifest content changes on a future apply (e.g., you rotated the build ID), Terraform destroys and recreates the `null_resource`, re-firing the provisioner. This is the correct "run this side-effect whenever X changes" pattern.

**`depends_on = [local_file.deploy_manifest]`.**
The expression `local_file.deploy_manifest.content` in `triggers` already creates an implicit graph edge. The explicit `depends_on` is a belt-and-suspenders guard: if a future refactor replaces the content reference with, say, a local variable that breaks the implicit edge, the ordering still holds. In code review, `depends_on` is self-documenting — it tells the next engineer "yes, this ordering is intentional and verified."

**Why `null_resource` and not a `provisioner` block on `local_file`?**
Provisioners on real resources run only at creation time and are notoriously hard to trigger on content change. `null_resource` with `triggers` gives you a clean, explicit re-execution model. It is the canonical Terraform pattern for side-effects.

## Apply and verify

```bash
cd ~/.kube-dojo-work/06-random-and-dependencies
terraform plan
terraform apply -auto-approve
cat deploy-manifest.txt        # app_name = brave-lynx, build_id = 4a2f8c3d (example)
terraform output app_name      # same random pet name
terraform output build_id      # same hex
bash courses/course-23-terraform-iac/challenges/06-random-and-dependencies/verify.sh
```

## Idempotency and re-runs

Run `terraform apply -auto-approve` a second time without changing anything. You should see:

```
null_resource.post_deploy: Refreshing state...
No changes. Your infrastructure matches the configuration.
```

The random values do not regenerate (they are in state), so the manifest content is unchanged, so the trigger hash is unchanged, so the `null_resource` is not recreated. This is correct idempotent behaviour.

Now change `byte_length = 4` to `byte_length = 6` in `random_id.build_id` and apply again. You should see three resources replaced: the `random_id`, the `local_file` (new content), and the `null_resource` (trigger fired). That cascade is the dependency graph working correctly.
