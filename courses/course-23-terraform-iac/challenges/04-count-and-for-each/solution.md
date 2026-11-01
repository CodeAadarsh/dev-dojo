# Solution — Iterate With for_each

Two edits to `main.tf`: swap the `for_each` value and fix `filename` + `content`.

```hcl
resource "local_file" "service_manifest" {
  for_each = local.services
  filename = "${path.module}/output/${each.key}.txt"
  content  = "Service: ${each.key}\nDescription: ${each.value}\n"
}
```

That's it. `outputs.tf` is already correct and needs no edits.

## Why each piece is required

**`for_each = local.services`.**
`local.services` is a `map(string)`, so Terraform iterates over it as a set of `{key, value}` pairs. Each pair becomes one instance of the resource, addressed as `local_file.service_manifest["auth-service"]` etc. The key is stable across plans — removing `"billing-service"` later only destroys that one resource, not every resource after it the way `count` would.

**`each.key` and `each.value`.**
Inside a `for_each` resource, `each.key` is the map key and `each.value` is the corresponding map value. They are only valid inside the resource block — outside, reference the whole collection as `local_file.service_manifest` (a map of objects).

**`${path.module}/output/`.**
`path.module` is the directory containing the `.tf` file at plan time. Using it (rather than a relative path like `./output/`) is correct when the module might be called from a parent module from a different working directory. The `local_file` provider 2.x creates missing parent directories automatically.

**The output — why `length()` works on a `for_each` resource.**
`local_file.service_manifest` is a `map(object(...))` when `for_each` is used. `length()` on a map returns the number of entries. If you had used `count` instead, the resource would be `list(object(...))` and `length()` still works, but the plan behaviour on key reordering is different (destructive).

## Apply and verify

```bash
cd ~/.kube-dojo-work/04-count-and-for-each
terraform plan     # should show: Plan: 3 to add, 0 to change, 0 to destroy
terraform apply -auto-approve
ls output/         # auth-service.txt  catalog-service.txt  payment-service.txt
cat output/auth-service.txt
bash courses/course-23-terraform-iac/challenges/04-count-and-for-each/verify.sh
```

## Extending the pattern

To add a fourth service, add one line to `locals.services`:

```hcl
"billing-service" = "Handles invoicing and subscription billing"
```

`terraform plan` will show exactly one resource to add, zero to change, zero to destroy. That's the difference from `count`.
