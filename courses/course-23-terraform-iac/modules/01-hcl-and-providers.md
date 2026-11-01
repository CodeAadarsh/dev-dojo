# HCL & Providers

> **Module 01 · Course 23** — Infrastructure-as-Code starts with a mindset shift, not a CLI command. Before you can write a single resource block you need to internalize what "declarative" means at the engine level, how HCL maps to that engine, and why providers are not just plugins but the entire surface area of what Terraform can touch.

You already write YAML for Kubernetes and config for CF apps. HCL will feel familiar in shape but different in semantics. This module is slow on "what is a variable" and fast on the parts that bite experienced engineers: version constraints, the lock file, and why `init` and `apply` are not interchangeable.

---

## Declarative vs imperative — the real difference

Most engineers have heard "declarative = you describe the end state." That's true but incomplete. The sharper way to think about it:

```
Imperative (Ansible, bash):         Declarative (Terraform):
----------------------------        --------------------------
Step 1: create the bucket           desired state: { bucket "my-bucket" }
Step 2: if bucket exists, skip        ↓
Step 3: set the ACL to private      Terraform reads actual state
Step 4: ...                         Terraform computes the diff
                                    Terraform executes only the delta
```

The engine owns the sequencing and idempotency. You don't write "if exists, skip" — you just describe what you want. This is the source of both Terraform's power and its footguns: **the engine's world model is its state file, not live reality.** When those diverge (drift), the engine doesn't know unless you tell it.

Consequences for an SDE who already knows Kubernetes:

| Concept | Kubernetes | Terraform |
|---------|-----------|-----------|
| Desired state | Deployment spec | `.tf` files |
| Actual state source of truth | etcd (live) | `.tfstate` (local or remote) |
| Diff engine | controller reconcile loop | `terraform plan` |
| Apply mechanism | kubelet | provider SDK calls |
| "Forced" refresh | controller resync | `terraform refresh` or `apply -refresh-only` |

Kubernetes controllers reconcile continuously. Terraform reconciles **on demand** — only when you run `plan` or `apply`. This is why drift is a first-class concern in Terraform and a secondary one in Kubernetes.

---

## HCL syntax — blocks, arguments, expressions

HCL (HashiCorp Configuration Language) compiles to a typed AST. The three primitives you need to internalize:

### Blocks

```hcl
# block_type  "label_1"  "label_2"  {  arguments  }
resource "aws_s3_bucket" "my_bucket" {
  bucket = "my-unique-bucket-name"
  tags = {
    Environment = "prod"
  }
}
```

A block has a **type** (`resource`), zero or more **labels** (type string + name string for resource blocks), and a **body** of arguments and nested blocks. Labels are part of the address Terraform uses internally — `aws_s3_bucket.my_bucket` is the full resource address above.

The five top-level block types you'll use constantly:

| Block type | Purpose | Labels |
|------------|---------|--------|
| `terraform` | backend, required_providers, required_version | none |
| `provider` | provider configuration (region, credentials) | alias (optional) |
| `resource` | a managed infrastructure object | type, name |
| `data` | a read-only query against a provider | type, name |
| `variable` / `output` / `locals` | parameterization | name (variable/output only) |

### Arguments and expressions

Arguments assign values inside a block body:

```hcl
resource "local_file" "greet" {
  filename = "${path.module}/hello.txt"   # string template expression
  content  = "Hello, ${var.name}!\n"      # variable reference in template
}
```

Expressions can be:
- **Literals** — `"string"`, `42`, `true`, `["a", "b"]`, `{ key = "val" }`
- **References** — `var.name`, `resource_type.name.attribute`, `data.type.name.attribute`, `local.value`
- **Template sequences** — `"${...}"` and `"%{for ...}"` / `"%{if ...}"`
- **Function calls** — `toset(var.cidrs)`, `lookup(var.map, "key", "default")`, `file("./config.json")`

> **Mental model: everything is an expression.** There is no "scripting" in HCL — no loops with side effects, no mutable variables. A `for` expression produces a value (a list or map); a `for_each` on a resource creates multiple instances declaratively. If you find yourself wanting to mutate state in HCL, that's a sign you're thinking imperatively and should reach for a `local` value or a module instead.

### Nested blocks vs arguments — a common confusion

```hcl
resource "aws_security_group" "web" {
  name = "web-sg"

  # ingress is a NESTED BLOCK (not an argument)
  ingress {
    from_port = 443
    to_port   = 443
    protocol  = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
```

Nested blocks cannot be assigned with `=`; they are opened with `{`. Confusing an argument for a nested block (or vice versa) produces a parser error that is sometimes cryptic — `terraform validate` catches it clearly before `plan`.

---

## Providers and the Terraform Registry

A provider is a compiled plugin that translates HCL resource blocks into API calls. Terraform itself has zero built-in resources — 100% of what it can create lives in providers.

```
┌──────────────────────────────────────────────────────────────────────────┐
│                           your .tf files                                 │
│  resource "aws_instance" "web" { ... }                                   │
│  resource "google_storage_bucket" "data" { ... }                         │
└────────────────┬────────────────────────────────────────────────────────┘
                 │  Terraform Core resolves the graph, calls providers
     ┌───────────┴──────────────────────────────────┐
     │                                              │
┌────▼─────────────────┐               ┌────────────▼────────────┐
│  hashicorp/aws        │               │  hashicorp/google        │
│  (compiled Go binary) │               │  (compiled Go binary)    │
│  calls AWS SDK        │               │  calls GCP REST APIs     │
└──────────────────────┘               └─────────────────────────┘
```

You declare which providers you need in the `terraform` block:

```hcl
terraform {
  required_providers {
    local = {
      source  = "hashicorp/local"
      version = "~> 2.4"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5.0, < 4.0.0"
    }
  }
  required_version = ">= 1.5.0"
}
```

The `source` string is `<namespace>/<type>`, which resolves to `registry.terraform.io/<namespace>/<type>`. `hashicorp/local` is the canonical short form for the local-file provider — fully `registry.terraform.io/hashicorp/local`. Third-party providers use their own namespace: `grafana/grafana`, `datadog/datadog`, etc.

---

## `terraform init` — what it actually does

`terraform init` is not "run this before any command." It's a specific operation with a specific output:

```
terraform init
    │
    ├── parse all .tf files for required_providers
    ├── resolve each provider source → registry URL
    ├── download provider binaries → .terraform/providers/
    ├── generate / update .terraform.lock.hcl
    └── configure the backend (if declared)
```

After `init`, your working directory contains:

```
.
├── main.tf
├── .terraform/
│   ├── providers/
│   │   └── registry.terraform.io/
│   │       └── hashicorp/local/2.4.1/darwin_arm64/
│   │           └── terraform-provider-local_v2.4.1_x5
│   └── terraform.tfstate          ← only present if a backend is configured
└── .terraform.lock.hcl
```

`.terraform/` is ephemeral — commit `.terraform.lock.hcl`, never `.terraform/`.

`init` must be re-run when you:
- Add or remove a `required_providers` entry
- Change the backend configuration
- Change provider version constraints in a way that doesn't match the lock file
- Clone the repo on a new machine (`.terraform/` is gitignored)

> **Init is not idempotent in the same sense as apply.** Running `init` a second time with no changes is harmless, but running `apply` without `init` after changing providers will either fail with a "provider not found" error or silently use a stale binary. The rule: `init` is the first command in every CI pipeline, every machine, every provider change.

---

## Provider version constraints

Version constraint strings follow a subset of semver notation:

| Constraint | Meaning | When to use |
|------------|---------|-------------|
| `= 2.4.1` | exact pin | almost never — ties you to one release |
| `>= 2.4.0` | minimum only | open-ended, can break on major bumps |
| `~> 2.4` | `>= 2.4, < 3.0` | typical — allows patch+minor, pins major |
| `~> 2.4.1` | `>= 2.4.1, < 2.5.0` | conservative — only patches |
| `>= 2.4, < 3.0` | explicit range | same as `~> 2.4` but explicit |

`~>` (the "pessimistic constraint operator") is idiomatic Terraform. For new projects `~> 2.0` (allowing all 2.x) is fine; for production configs touching billing or IAM, `~> 2.4.1` (patches only) is safer.

`required_version` on the `terraform` block constrains the **Terraform CLI binary**, not providers. If a teammate runs Terraform 1.3 against a config requiring `>= 1.5`, they get a hard error before `init` even resolves providers. Use it — version drift in Terraform itself causes silent behaviour differences.

---

## The dependency lock file

`.terraform.lock.hcl` records the exact provider version and checksums that `init` resolved. It is the equivalent of `package-lock.json` — commit it.

```hcl
# .terraform.lock.hcl — generated by terraform init
provider "registry.terraform.io/hashicorp/local" {
  version     = "2.4.1"
  constraints = "~> 2.4"
  hashes = [
    "h1:8newZklam4f...",
    "zh:0a4f...",
    # ... one hash per platform
  ]
}
```

The `hashes` block contains two hash formats:
- `h1:` — the hash of the zip archive
- `zh:` — per-platform executable hashes (populated when you run `init -upgrade` or `providers lock`)

Without the lock file committed:
- Every CI job resolves versions independently → potential version drift
- A supply-chain attack that replaces a provider binary is not caught
- `terraform init` on a new machine may install a different (newer) version than your local run

To add cross-platform checksums (e.g. your Mac vs Linux CI):

```bash
terraform providers lock \
  -platform=linux_amd64 \
  -platform=darwin_arm64
```

This fetches checksums for both platforms and writes them to the lock file without downloading the actual binaries.

> **When to run `init -upgrade`:** Use this consciously — it re-resolves versions within your declared constraints and updates the lock file. In a team setting, run it, review the diff on `.terraform.lock.hcl`, and commit it deliberately. Do not run `init -upgrade` as part of a CI pipeline; that's `init` (which respects the lock file).

---

## Debugging HCL & Providers

Most failures in this layer are caught before any API call is made, which makes them fast to diagnose — `terraform validate` and `terraform init` give you the full picture.

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `Error: Failed to query available provider packages` | Typo in provider `source`, or no internet / registry unreachable | Check `source = "namespace/type"` spelling; `curl https://registry.terraform.io/v1/providers/hashicorp/local/versions` to verify registry is up |
| `Error: Required provider not installed` | Ran `apply` / `plan` without `init`, or `.terraform/` was deleted | `terraform init` |
| `Error: lock file conflict` or `Error: Inconsistent dependency lock file` | Provider in `.tf` changed but lock file wasn't regenerated | `terraform init -upgrade` (review the lock diff before committing) |
| `Error: Unsupported Terraform Core version` | `required_version` constraint excludes the CLI you're running | `tfenv use <version>` or `asdf install terraform <version>` |
| `Error: duplicate required provider` | Same provider declared in multiple `required_providers` blocks | Consolidate into one `terraform` block — exactly one per root module |
| `provider produced inconsistent final plan` | Provider bug or provider version regression | Check the provider's GitHub issues; pin to the last known-good version in the lock file |

### Diagnose each — the exact sequence

**Provider not found (registry 404).** The error names the exact source string. First confirm it with `validate`, then test the registry directly:

```bash
terraform validate
# Error: Failed to query available provider packages
#   Could not retrieve the list of available versions for provider
#   hashicorp/awss: provider registry returned 404.

# check the registry manually — no auth needed
curl -s https://registry.terraform.io/v1/providers/hashicorp/awss/versions | head -5
# {"errors":["Not Found"]} ← typo confirmed
```

**Version conflict between lock file and constraints.** The lock file records the version that was installed; the `.tf` file may have tightened the constraint since then:

```bash
# current lock: hashicorp/local 2.3.0
# constraint changed to: version = "~> 2.4"
terraform init
# Error: Inconsistent dependency lock file
#   The following dependency selections recorded in the lock file are inconsistent
#   with the current configuration:
#     - provider registry.terraform.io/hashicorp/local: locked version selection
#       2.3.0 doesn't match ~> 2.4
terraform init -upgrade   # resolves 2.4.x, rewrites lock file
git diff .terraform.lock.hcl   # review before committing
```

**Running `plan`/`apply` before `init`.** Unlike most tools, Terraform gives a specific error rather than silently using a bad state:

```bash
terraform plan
# Error: Required plugins are not installed
#   The working directory must be initialized before using this command.
# Solution: just init first
terraform init && terraform plan
```

> **War story.** A platform team I worked with had a CI job that ran `terraform apply` directly from a Docker image baked with `.terraform/` pre-included to save the 30-second init time. It worked for six months until a provider security advisory dropped and the team ran `terraform init -upgrade` locally, updated the lock file, and merged. The next CI run picked up the old embedded `.terraform/` — the pre-baked binary hadn't been refreshed. The provider version in CI drifted silently from the lock file version for three weeks. Two PRs that changed IAM policy bindings applied successfully against a provider version that had a different interpretation of `binding.members` — and neither engineer noticed until audit logs surfaced permissions that shouldn't exist. The fix was one line: remove `.terraform/` from the Docker image and run `terraform init` at CI start, reading the committed lock file. Baking provider binaries into CI images is an anti-pattern; the lock file exists precisely so init is fast (checksums verify the download) and reproducible.

---

## Checkpoint

You're ready for Module 02 when you can, without looking anything up:

1. Explain why Terraform's reconciliation model differs from Kubernetes controllers, and what that means for drift.
2. Name the five top-level HCL block types and give one example use of each.
3. Write a `required_providers` block for `hashicorp/local ~> 2.4` and `hashicorp/random >= 3.5, < 4.0`.
4. Describe exactly what `terraform init` produces in the working directory.
5. Explain the difference between `~> 2.4` and `~> 2.4.1` and when you'd choose each.
6. State what `.terraform.lock.hcl` records and why it must be committed.
7. Diagnose the "Inconsistent dependency lock file" error and fix it with one command.
8. Explain why baking `.terraform/` into a CI image is an anti-pattern.
9. Add checksums for `linux_amd64` to an existing lock file without downloading the binary on Linux.

➡ Next up: **Resources, Variables, Outputs & Locals** — the blocks you'll write 90% of the time, the dependency graph, and why `depends_on` is a last resort.
