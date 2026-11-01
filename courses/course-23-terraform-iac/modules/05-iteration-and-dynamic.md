# Iteration: count, for_each & dynamic

> **Module 05 · Course 23** — The moment your infra grows past "one of everything," you hit the repetition problem: do you copy-paste five nearly-identical `resource` blocks, or do you make Terraform do the loop? This module covers every looping primitive Terraform gives you, why `for_each` beats `count` in most real situations, and the one footgun that has caused more unplanned destroys than any other single Terraform mistake.

You already know variables and resources. The gap between "I can write Terraform" and "I can write Terraform that scales" is almost entirely this module's content.

---

## count — indexed repetition

`count` is the original iteration primitive. Set it to an integer and Terraform creates that many instances, addressable as `resource_type.name[0]`, `resource_type.name[1]`, etc.

```hcl
resource "local_file" "env_config" {
  count    = 3
  filename = "${path.module}/output/config-${count.index}.txt"
  content  = "environment = env${count.index}\n"
}
```

Inside the block, `count.index` gives the zero-based position. Reference from outside:

```hcl
output "first_config" {
  value = local_file.env_config[0].filename
}

output "all_configs" {
  value = local_file.env_config[*].filename   # splat: collect one attr from every instance
}
```

`count` works well when:
- The number of instances is all that varies (identical resources)
- You only need a boolean "create or not" pattern: `count = var.enable_monitoring ? 1 : 0`

The "create or not" pattern is the single legitimate everyday use of `count`. For the conditional reference, use a ternary on the output:

```hcl
resource "local_file" "debug_log" {
  count    = var.debug ? 1 : 0
  filename = "${path.module}/output/debug.log"
  content  = "debug enabled\n"
}

output "debug_log_path" {
  # When count = 0, the list is empty; the conditional avoids a panic on [0]
  value = var.debug ? local_file.debug_log[0].filename : null
}
```

---

## The index-churn footgun

Here is the most destructive thing `count` does, and it surprises everyone once.

Suppose you manage three files driven by a list:

```hcl
variable "environments" {
  default = ["dev", "staging", "prod"]
}

resource "local_file" "env_config" {
  count    = length(var.environments)
  filename = "${path.module}/output/${var.environments[count.index]}.txt"
  content  = "env = ${var.environments[count.index]}\n"
}
```

Terraform maps positions to resources:

```
local_file.env_config[0]  →  dev
local_file.env_config[1]  →  staging
local_file.env_config[2]  →  prod
```

Now someone removes `"staging"` from the list:

```
variable "environments" = ["dev", "prod"]
```

Terraform recomputes the mapping:

```
local_file.env_config[0]  →  dev       (unchanged — ok)
local_file.env_config[1]  →  prod      (was staging — Terraform destroys staging, creates prod at index 1)
local_file.env_config[2]  →  (gone)    — Terraform destroys what was prod
```

Result: two destroys + one create instead of one destroy. On real infrastructure — VMs, databases, DNS records — this causes outages. On anything stateful, it loses data.

```
┌────────────────────────────────────────────────────────────────────┐
│  count=3 list       │  after removing "staging"                    │
│                     │                                              │
│  [0] dev   ←──────  │  [0] dev      (no change)                   │
│  [1] staging        │  [1] prod  ← Terraform: destroy[1], create  │
│  [2] prod   ←──────  │             (was staging) then assign prod  │
│                     │  [2]       ← destroy (was prod)             │
└────────────────────────────────────────────────────────────────────┘
```

The root cause: count addresses by *position*, not by *identity*. Every list reorder is a potential cascade of destroys.

---

## for_each — the right default for most loops

`for_each` addresses resources by a *string key* you control, not by position. The key is stable across list additions, deletions, and reorders.

`for_each` accepts either:
- a **map**: `{ "dev" = "us-east-1", "prod" = "eu-west-1" }`
- a **set of strings**: `toset(["dev", "staging", "prod"])`

```hcl
variable "environments" {
  default = {
    dev     = "10.0.0.0/24"
    staging = "10.0.1.0/24"
    prod    = "10.0.2.0/24"
  }
}

resource "local_file" "env_config" {
  for_each = var.environments

  filename = "${path.module}/output/${each.key}.txt"
  content  = "env   = ${each.key}\ncidr  = ${each.value}\n"
}
```

Inside the block, `each.key` is the map key and `each.value` is the value (or the element when iterating a set). The resource address becomes `local_file.env_config["dev"]`, `local_file.env_config["staging"]`, etc.

Removing `"staging"` from the map now does exactly one thing: `destroy local_file.env_config["staging"]`. Keys `"dev"` and `"prod"` are untouched — Terraform doesn't even plan a change for them.

### Converting a list to a set for for_each

`for_each` rejects plain lists because lists have no uniqueness guarantee. Wrap with `toset()`:

```hcl
variable "regions" {
  type    = list(string)
  default = ["us-east-1", "eu-west-1", "ap-southeast-1"]
}

resource "random_id" "region_token" {
  for_each    = toset(var.regions)
  byte_length = 4
  keepers     = { region = each.key }
}
```

`toset()` deduplicates and makes the type concrete. If the list can have duplicates in a source you don't control, deduplicate deliberately rather than let `toset()` silently drop entries.

### Collecting outputs from for_each resources

With `count` you used splat (`[*]`). With `for_each` use a `for` expression to project:

```hcl
output "config_files" {
  value = { for k, v in local_file.env_config : k => v.filename }
}

output "all_filenames" {
  value = [for v in local_file.env_config : v.filename]
}
```

---

## for expressions

`for` expressions produce new collections from existing ones — they do not create resources. They're the Terraform equivalent of `map()` and `filter()`.

```hcl
# List → list: uppercase every string
locals {
  upper_envs = [for e in var.environments : upper(e)]
}

# Map → map: flip key/value
locals {
  region_to_env = { for env, region in var.env_regions : region => env }
}

# Filter: only prod-like names
locals {
  prod_envs = [for e in var.environments : e if can(regex("prod", e))]
}

# Map → list of objects
locals {
  env_objects = [
    for k, v in var.environments : {
      name = k
      cidr = v
    }
  ]
}
```

The pattern `{ for k, v in map : k => transform(v) }` is your daily workhorse for reshaping data before feeding it into `for_each` or outputs.

---

## dynamic blocks

`dynamic` generates repeated *nested* blocks inside a resource — things like `ingress` rules, `tag` stanzas, `environment` variables. You cannot use `for_each` on nested blocks directly; you need `dynamic`.

```hcl
variable "allowed_ports" {
  default = [80, 443, 8080]
}

# Using hashicorp/local for a demo — imagine this is a firewall rule resource
resource "local_file" "firewall_rules" {
  filename = "${path.module}/output/firewall.txt"

  content = join("\n", [
    for port in var.allowed_ports : "ALLOW TCP ${port}"
  ])
}
```

A realistic pattern with `dynamic` on a resource that has nested blocks:

```hcl
variable "env_vars" {
  default = {
    LOG_LEVEL    = "info"
    FEATURE_FLAG = "true"
  }
}

# Pseudo-example; replace local_file with your provider's resource
resource "local_file" "app_env" {
  filename = "${path.module}/output/app.env"

  content = join("\n", [
    for k, v in var.env_vars : "${k}=${v}"
  ])
}
```

For providers that expose nested blocks (security groups, IAM policy statements, ECS task environment arrays), `dynamic` looks like this:

```hcl
# Pattern — adapt to your provider
resource "example_security_group" "web" {
  name = "web-sg"

  dynamic "ingress" {
    for_each = var.allowed_ports
    content {
      from_port = ingress.value
      to_port   = ingress.value
      protocol  = "tcp"
    }
  }
}
```

The iterator inside `content` defaults to the block label (`ingress.value`, `ingress.key` if iterating a map). Override with `iterator = "rule"` on the `dynamic` block if the default name conflicts with a field name.

Avoid nesting `dynamic` inside `dynamic` — the result is hard to reason about and usually a sign that a helper module should exist instead.

---

## count vs for_each — the decision rule

| Situation | Use |
|-----------|-----|
| Boolean "create or skip" | `count = condition ? 1 : 0` |
| N identical resources where identity doesn't matter | `count = N` |
| Resources driven by a map or meaningful keys | `for_each = map` |
| Resources driven by a list of unique strings | `for_each = toset(list)` |
| Resources driven by a list where order matters and keys are stable | `for_each` — add an explicit key field if needed |
| Repeating nested blocks inside a resource | `dynamic` |
| Any case where removing a middle element would shift later indices | **for_each, always** |

The safe default: reach for `for_each` first. Switch to `count` only when you can prove the resources are truly position-indifferent (e.g., "3 identical worker nodes where the index has no semantic meaning and you'll never insert/remove from the middle").

---

## Debugging Iteration

Most iteration bugs surface at plan time as confusing diff output, or at apply time as surprising destroys. Use `terraform plan` output as your main diagnostic tool — read it carefully before every apply.

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `for_each map keys must be known` — plan fails with "values not yet known" | A `for_each` key depends on a resource output that hasn't been applied yet (e.g. `resource.foo.id`) | Break the apply into two steps: apply the resource that generates the key first, then the for_each resource. Or restructure so keys come from input variables, not computed outputs. |
| `for_each map keys must be known at plan time` with `toset(list)` | The list itself is computed (e.g. comes from `data` source or another resource output) | Same as above — keys must be statically knowable at plan time. Use `-target` as a one-time workaround to establish the upstream resource first (see Module 06 for -target risks). |
| Plan shows N destroys + N creates when you only wanted 1 destroy | Using `count` with a list; removed an item from the middle | Migrate to `for_each` using `moved` blocks (see below) or accept a planned migration with manual state moves |
| Splat `[*]` returns empty list unexpectedly | Resource uses `for_each` not `count` — splat only works on count-addressed resources | Use `values(resource.name)[*].attr` for for_each, or a `for` expression |
| `each.key` / `each.value` not available | Inside a `count`-based resource, not a `for_each` one | Switch to `for_each`, or use `count.index` |
| `dynamic` block not iterating | Iterator variable name wrong — defaults to block label, not "item" | Check `content` block: use `<block_label>.value` or set `iterator = "item"` on the `dynamic` stanza |

### Migrating count to for_each with moved blocks

When you need to switch an existing `count` resource to `for_each` without destroying and recreating everything, use `moved`:

```hcl
moved {
  from = local_file.env_config[0]
  to   = local_file.env_config["dev"]
}

moved {
  from = local_file.env_config[1]
  to   = local_file.env_config["staging"]
}

moved {
  from = local_file.env_config[2]
  to   = local_file.env_config["prod"]
}
```

`moved` blocks tell Terraform "this old address is now this new address in state." The plan will show a rename, not a destroy+create. Remove the `moved` blocks after the next apply.

> **War story.** During a platform migration I was building a module to create one `random_id` per service for stable resource naming — a seemingly trivial task. I drove it with `count = length(var.services)` because the list felt "obviously stable." Six weeks later, a new service was inserted alphabetically in the middle of the list. The next `terraform apply` in our CD pipeline planned to destroy and recreate 14 downstream resources, including a database, because index 4 now pointed at a different service name. The apply was caught in review — barely — and took half a day to unwind with manual `terraform state mv` commands. I've never used `count` on a list of named things since. The rule I wrote in our Terraform style guide that day: *if the element has a name, use that name as the key.*

---

## Checkpoint

You're solid on iteration when you can, without looking anything up:

1. Explain in one sentence why removing the middle element of a `count`-driven list causes unplanned destroys.
2. Write a `for_each` resource driven by a `map(string)` variable and correctly reference `each.key` and `each.value`.
3. Convert a `list(string)` to a form `for_each` accepts, and state the one edge case to watch for.
4. Use a `for` expression to transform a map of `{ env => cidr }` into a list of `"env: cidr"` strings.
5. Write a `dynamic` block that generates repeated nested blocks from a variable.
6. State the decision rule for `count` vs `for_each` in one table row.
7. Explain what `moved` blocks do and when to use them.
8. Reproduce the exact error message when `for_each` keys are not yet known, and state the two ways to fix it.

➡ Next up: **Workflow & Environments** — the `plan → apply → destroy` lifecycle, workspaces, tfvars, and how Terraform lives inside a CI pipeline.
