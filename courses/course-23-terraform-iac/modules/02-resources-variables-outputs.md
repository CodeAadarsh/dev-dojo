# Resources, Variables, Outputs & Locals

> **Module 02 · Course 23** — Everything you provision lives in a `resource` block. Everything you parameterize lives in a `variable`. Everything you export lives in an `output`. Between them sits `locals` — the computed intermediary that keeps your configs DRY without the footguns of mutable state. This module covers all four, plus the dependency graph that connects them, because understanding the graph is what separates engineers who fight Terraform from engineers who reason with it.

---

## Resource blocks

A resource block tells Terraform to manage a real infrastructure object:

```hcl
resource "TYPE" "NAME" {
  argument = value
}
```

`TYPE` is always `<provider>_<resource>` — e.g. `local_file`, `aws_instance`, `google_container_cluster`. `NAME` is your local label within the config; it has no meaning outside Terraform. Together they form the **resource address**: `local_file.greet`, `aws_instance.web`.

```hcl
resource "local_file" "greet" {
  filename = "${path.module}/output/hello.txt"
  content  = "Hello from Terraform ${terraform.workspace}!\n"
}
```

Terraform manages the full lifecycle: `create`, `read` (to detect drift), `update`, and `destroy`. The provider SDK defines which arguments are **required**, which are **optional**, and which are **computed** (set by the provider after creation and read back into state).

### Computed attributes — the source of `(known after apply)`

Some fields can only be known after the resource exists:

```hcl
resource "random_id" "suffix" {
  byte_length = 4
}

resource "local_file" "named" {
  filename = "${path.module}/output/${random_id.suffix.hex}.txt"
  content  = "id is ${random_id.suffix.id}"
}
```

`random_id.suffix.hex` is a computed attribute. During `plan`, Terraform prints `(known after apply)` for any resource that depends on it. This is not an error — it's the engine telling you it can infer the dependency but not the value yet. It becomes a problem when you use a computed value as a resource *count* or *for_each key*, because the graph can't be built without a known cardinality. See Debugging below.

---

## Data blocks — read-only queries

`data` blocks are read during `plan` (not `apply`). They query existing infrastructure rather than creating it:

```hcl
data "local_file" "config" {
  filename = "${path.module}/config.json"
}

output "config_contents" {
  value = data.local_file.config.content
}
```

The address is `data.TYPE.NAME.ATTRIBUTE`. Use `data` to:
- Look up an existing resource you did not create with Terraform (e.g. a shared VPC)
- Read a file or external state without managing it
- Compute a value from a provider query (AMI IDs, availability zones)

> **Resource vs data: ownership.** A `resource` block means "Terraform owns this — if I delete this block, Terraform will destroy the object." A `data` block means "Terraform reads this — if I delete this block, the object is untouched." Confusing them is how you accidentally `terraform destroy` a shared resource that twelve other services depend on.

---

## Input variables

Variables make configs reusable. Declare them in `variables.tf` by convention (filename is not significant — Terraform merges all `.tf` files in the working directory):

```hcl
variable "environment" {
  type        = string
  description = "Deployment environment: dev, staging, or prod."
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "replica_count" {
  type    = number
  default = 1
}

variable "tags" {
  type = map(string)
  default = {}
}

variable "allowed_cidrs" {
  type    = list(string)
  # no default → required at plan time
}
```

### Types

| HCL type | Example | Notes |
|----------|---------|-------|
| `string` | `"us-east-1"` | default type when omitted |
| `number` | `3` | int or float |
| `bool` | `true` | |
| `list(T)` | `["a", "b"]` | ordered, indexed |
| `set(T)` | `toset(["a", "b"])` | unordered, unique — good for `for_each` |
| `map(T)` | `{ key = "val" }` | string keys |
| `object({...})` | `{ name = string, size = number }` | structured, field-level typing |
| `tuple([...])` | `[string, number]` | typed positional list |
| `any` | anything | loses type safety — avoid |

### Supplying values

In order of precedence (highest first):
1. `-var="name=value"` CLI flag
2. `-var-file="file.tfvars"` CLI flag
3. `*.auto.tfvars` or `*.auto.tfvars.json` files in the working directory
4. `terraform.tfvars` or `terraform.tfvars.json` in the working directory
5. `TF_VAR_name` environment variables
6. `default` in the variable declaration
7. Interactive prompt (only in interactive terminals; CI fails if a required var has no value)

```bash
# Override a single var
terraform plan -var="environment=staging"

# Use a var file (common in CI)
terraform apply -var-file="prod.tfvars"

# Via env (useful for secrets — no var file on disk)
export TF_VAR_db_password="$(vault read -field=password secret/db)"
terraform apply
```

### Validation blocks

Validation runs before `plan` reaches the provider. Use it aggressively:

```hcl
variable "bucket_prefix" {
  type = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,20}$", var.bucket_prefix))
    error_message = "bucket_prefix must be 3-21 lowercase alphanumeric chars, starting with a letter."
  }
}
```

`can()` returns `false` rather than erroring if the inner expression fails — the idiom for wrapping `regex()` and `lookup()` in validations.

---

## Outputs

Outputs expose values from your configuration for use by humans, CI pipelines, or other Terraform configs (via remote state data sources):

```hcl
output "file_path" {
  value       = local_file.greet.filename
  description = "Absolute path of the generated file."
}

output "random_suffix" {
  value     = random_id.suffix.hex
  sensitive = true   # masked in terminal output; still in state
}
```

`sensitive = true` masks the value in `terraform output` and plan output, but it is stored in plaintext in the state file. Sensitivity does not cascade — if you embed a sensitive output in a non-sensitive string, the non-sensitive string is printed. Terraform 1.1+ attempts to cascade sensitivity tracking, but do not rely on it for secrets.

```bash
terraform output                          # all non-sensitive outputs
terraform output file_path                # one output by name
terraform output -json | jq '.file_path.value'   # machine-readable
terraform output -raw random_suffix       # raw value, no quotes (useful in shell)
```

---

## Locals

`locals` are named computed values — expressions evaluated once and reused:

```hcl
locals {
  name_prefix = "${var.environment}-${var.project}"
  common_tags = {
    Environment = var.environment
    ManagedBy   = "terraform"
    Project     = var.project
  }
  is_production = var.environment == "prod"
}

resource "local_file" "config" {
  filename = "${path.module}/output/${local.name_prefix}-config.txt"
  content  = local.is_production ? "PROD CONFIG\n" : "NON-PROD CONFIG\n"
}
```

`locals` are not variables — they cannot be overridden from outside the module. They are pure expressions, evaluated at plan time. Use them to:
- Avoid repeating the same expression in multiple places (DRY)
- Give complex expressions a readable name
- Compute a value derived from multiple variables

> **Locals vs variables: the ownership line.** A `variable` is an input contract — it's part of the module's public interface and callers can override it. A `local` is an internal computed value — callers have no access and cannot override it. If you find yourself wishing you could override a `local` from outside, it should be a `variable` instead.

---

## Expressions and functions

HCL's built-in functions cover the common transformations. A sampler of the ones you'll reach for constantly:

```hcl
# String
local.name_prefix    = lower(var.name)
local.trimmed        = trimspace(var.input)
local.joined         = join("-", ["a", "b", "c"])       # "a-b-c"
local.parts          = split(",", var.csv)              # ["a","b","c"]
local.safe_name      = replace(var.name, "/[^a-z0-9]/", "-")

# Collections
local.unique_envs    = toset(var.environments)
local.env_map        = { for e in var.environments : e => true }
local.filtered       = [for t in var.tags : t if t != ""]
local.merged_tags    = merge(local.common_tags, var.extra_tags)
local.flat_list      = flatten([["a","b"], ["c","d"]])  # ["a","b","c","d"]

# Type coercion
local.as_number      = tonumber(var.string_count)
local.as_string      = tostring(var.port)

# Conditional
local.replicas       = var.environment == "prod" ? 3 : 1

# Existence
local.with_default   = lookup(var.optional_map, "key", "fallback")
local.is_set         = var.optional_var != null
```

The **`for` expression** is the most powerful — it transforms collections without requiring a for-loop construct:

```hcl
# list → map (for for_each)
local.instance_map = {
  for idx, name in var.names :
  name => idx
}

# map → filtered map
local.prod_only = {
  for k, v in var.all_envs :
  k => v
  if v.tier == "prod"
}
```

---

## Implicit dependencies and the graph

Terraform builds a directed acyclic graph (DAG) of all resources and data sources. An **implicit dependency** is created whenever one block references an attribute of another:

```hcl
resource "random_id" "suffix" {
  byte_length = 4
}

resource "local_file" "output" {
  filename = "${path.module}/out-${random_id.suffix.hex}.txt"  # implicit dep
  content  = "generated\n"
}
```

Because `local_file.output` references `random_id.suffix.hex`, Terraform infers that `random_id.suffix` must be created first. You never write this ordering explicitly — the graph engine handles it.

Visualize the graph:

```bash
terraform graph | dot -Tsvg > graph.svg   # requires graphviz
terraform graph -type=plan                 # shows the plan graph, not apply
```

### Explicit dependencies — `depends_on`

`depends_on` is an escape hatch for when the dependency is real but not expressed through attribute references:

```hcl
resource "local_file" "marker" {
  filename = "${path.module}/ready.txt"
  content  = "cluster ready\n"

  # local_file doesn't reference any attribute of null_resource.bootstrap,
  # but we need it to run first
  depends_on = [null_resource.bootstrap]
}
```

Use `depends_on` only when necessary — it adds edges the graph engine can't infer. Overusing it produces a serialized, slow apply and hides real dependency bugs. If you're adding `depends_on` everywhere, it's a sign the resources should be reorganized or the config has a structural problem.

> **The graph is the model.** Every ordering guarantee in Terraform comes from the graph. If two resources have no dependency path between them (direct or transitive), Terraform applies them in parallel. The apply log shows `...creating 3 resources simultaneously`. If your apply is unexpectedly serial, you probably have a `depends_on` chain that doesn't need to be there, or a reference that forces sequencing you didn't intend.

---

## Debugging Resources, Variables, Outputs & Locals

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `Error: Cycle in the resource dependency graph` | Two resources reference each other's attributes (A → B and B → A) | Identify the cycle with `terraform graph`; break it by extracting the circular value to a `local` or `variable`, or restructuring the dependency |
| `Error: Invalid value for input variable` | Validation block condition failed | Read the `error_message`; fix the calling value or loosen the constraint |
| `Error: count/for_each depends on resource attributes that cannot be determined until apply` | Using a computed attribute as `for_each` key or `count` | Replace the computed value with a known static map/set; move the computed value inside the resource body instead of the count/for_each meta-argument |
| `Error: Unsupported attribute` | Referencing `resource_type.name.attribute` that doesn't exist | `terraform providers schema -json | jq '.provider_schemas'` to list valid attributes; check provider docs |
| `Warning: Output "X" is deprecated and planned for removal` | Depends on a provider resource marked deprecated | Migrate to the replacement resource type named in the warning |
| Type mismatch: `string required, got number` | Variable declared as `string` received a number, or function returned wrong type | Explicit coercion: `tostring()`, `tonumber()`; or fix the variable's `type` declaration |
| `sensitive value passed as argument and used in non-sensitive context` | Embedding a `sensitive = true` output in a non-sensitive resource argument | Terraform marks the entire resource as sensitive-derived; suppress with `nonsensitive()` only if you're certain the value is safe to expose |

### Diagnosing cycles

A cycle error prints the chain:

```
Error: Cycle: local_file.a, local_file.b
```

Get the full graph to find where the loop enters:

```bash
terraform graph 2>/dev/null | grep -E '(local_file\.a|local_file\.b)'
# -> "local_file.a" -> "local_file.b" [style=dashed]
# -> "local_file.b" -> "local_file.a" [style=dashed]
```

The fix is always to break the circular reference. The most common real case: resource A needs resource B's ID, and resource B needs resource A's output. Extract the shared value to a `variable` or a `local` that both can read without referencing each other.

### Diagnosing unknown values at plan time

```bash
terraform plan
# Error: Invalid for_each argument
#   The "for_each" map includes keys derived from resource attributes that
#   cannot be determined until apply, and so Terraform cannot determine the
#   full set of keys that will identify the instances of this resource.
```

The fix: replace the computed `for_each` key with a known value (a hardcoded set, a variable, or a `toset()` of literal strings). The value itself can still come from the computed attribute; only the *key* must be known at plan time.

```hcl
# WRONG — computed ID as for_each key
resource "aws_security_group_rule" "each" {
  for_each = { for r in aws_instance.nodes : r.id => r }  # id unknown at plan
  ...
}

# RIGHT — use a known index as key; reference the computed attribute inside
resource "aws_security_group_rule" "each" {
  for_each = { for idx, r in aws_instance.nodes : idx => r }  # idx known
  source_security_group_id = each.value.id
  ...
}
```

> **War story.** A colleague was building a multi-region deployment where each region got a set of firewall rules keyed by the VM instance IDs that the IaaS provider assigned at creation time. The `terraform plan` passed fine on the first ever `apply` (state was empty, count was 0, no keys to resolve). On the second run — after the VMs existed in state — Terraform tried to build the `for_each` map from the stored IDs. But on a fresh environment (CI teardown + rebuild), it hit the "unknown at plan time" error because the IDs don't exist yet. The team had been living with `terraform apply -target=module.vms && terraform apply` as a two-pass workaround for three months, which silently broke their `-auto-approve` pipeline. The fix was to drive `for_each` from a statically-declared map of region→index and reference the instance IDs inside the resource bodies. One refactor, zero two-pass hacks.

---

## Checkpoint

You're ready for Module 03 when you can, without looking anything up:

1. Distinguish between a `resource` block and a `data` block in terms of lifecycle and ownership.
2. Declare a variable with type `list(string)`, a non-null default, and a validation that rejects empty lists.
3. Explain where Terraform looks for variable values and in what order of precedence.
4. Write a `for` expression that transforms a `list(string)` into a `map(number)` where each key is the string and each value is its index.
5. Explain what `(known after apply)` means during `terraform plan` and when it becomes a problem.
6. State the rule for when to use `depends_on` and why overusing it is an anti-pattern.
7. Diagnose a cycle error by using `terraform graph` and describe the structural fix.
8. Explain why `sensitive = true` on an output does not protect the value in state.
9. Fix the "for_each depends on resource attributes unknown until apply" error without resorting to `-target`.

➡ Next up: **State** — the thing that makes Terraform's declarative model work, and the thing that destroys teams that don't treat it with care.
