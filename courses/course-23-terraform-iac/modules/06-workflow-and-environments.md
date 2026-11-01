# Workflow & Environments

> **Module 06 · Course 23** — Writing HCL is the easy part. Operating Terraform across environments — staging, prod, hotfixes, and CI — is where most teams accumulate subtle, expensive mistakes. This module covers the full lifecycle, how to split environments without duplicating everything, and what "Terraform in CI" actually looks like when it's done right.

You already know `init`, `plan`, and `apply` exist. The gap is understanding what each one *does* to state, why the order is not optional, and what goes wrong when you skip steps.

---

## The plan → apply → destroy lifecycle

Terraform operates in a tight loop: **read the world, compare to desired state, generate a diff, execute the diff**.

```
┌──────────────┐   reads providers   ┌───────────────────────┐
│ .tf files    │ ─────────────────→  │ terraform plan        │
│ (desired)    │                     │                        │
└──────────────┘                     │  ① read state file    │
┌──────────────┐   reads current     │  ② call provider APIs │
│ state file   │ ─────────────────→  │     (describe real    │
│ (.tfstate)   │                     │      infra)           │
└──────────────┘                     │  ③ diff desired vs    │
                                     │     actual            │
                                     │  ④ emit plan file     │
                                     └───────────┬───────────┘
                                                 │ terraform apply [plan]
                                                 ▼
                                     ┌───────────────────────┐
                                     │ terraform apply       │
                                     │  ① execute changes    │
                                     │  ② update state       │
                                     └───────────────────────┘
```

### init

Downloads provider plugins and modules into `.terraform/`. Must re-run when you add a new provider or change module sources. The lock file (`.terraform.lock.hcl`) pins provider versions — commit this to version control.

```bash
terraform init                    # first time and after provider/module changes
terraform init -upgrade           # pull newer provider versions (updates lock file)
```

### plan

Reads the current state (remote or local), calls every provider's read API to reconcile drift, and produces a diff. The diff shows `+` (create), `~` (update in-place), `-/+` (destroy and recreate), and `-` (destroy).

```bash
terraform plan                    # review diff interactively
terraform plan -out=tfplan        # save plan to file for CI (see below)
terraform plan -var-file=prod.tfvars
terraform plan -destroy           # shows what 'destroy' would do, without doing it
```

**The plan file is a binary snapshot** of exactly what Terraform will do. When you pass a plan file to `apply`, Terraform is *contractually bound* to execute only that diff — it does not re-plan. This is the only safe way to do Terraform in CI (see CI section below).

### apply

Executes the plan. If you run `terraform apply` without a saved plan file, Terraform re-plans interactively — which opens a window for drift between the CI plan and the actual apply (someone might merge a change between those two steps).

```bash
terraform apply                   # interactive: re-plans + prompts for confirmation
terraform apply tfplan            # non-interactive: executes the saved plan exactly
terraform apply -auto-approve     # skip confirmation (fine in CI; dangerous interactively)
```

### destroy

`terraform destroy` is sugar for `terraform apply -destroy`. It destroys all resources tracked in the current state. Use `plan -destroy` first to review what will be lost.

```bash
terraform plan -destroy -out=destroy.plan
terraform apply destroy.plan
```

Never run `destroy` against a production workspace without a saved plan reviewed by a second pair of eyes.

---

## Variables — tfvars and precedence

Variables feed values into your configuration without hardcoding environment-specific data.

### Sources, in order of increasing precedence

1. Default values in `variable` blocks
2. `terraform.tfvars` (auto-loaded if present)
3. `*.auto.tfvars` files (auto-loaded alphabetically)
4. `-var-file=file.tfvars` on the command line
5. `-var="name=value"` on the command line
6. `TF_VAR_name` environment variables (override everything except explicit `-var`)

```bash
terraform apply -var-file=prod.tfvars -var="debug=false"
```

### File layout convention

```
infra/
  main.tf
  variables.tf
  outputs.tf
  terraform.tfvars       # dev defaults (committed, non-secret)
  prod.tfvars            # production overrides (committed, non-secret)
  secrets.auto.tfvars    # DO NOT COMMIT — add to .gitignore
```

Never commit secret values in tfvars. Use environment variables (`TF_VAR_db_password`) or a secrets manager integration (see Module 07).

---

## Workspaces vs directory-per-env vs Terragrunt

Three common patterns exist for splitting environments. Pick deliberately — mixing them creates the worst of all worlds.

### Workspaces

Workspaces share a single backend configuration but isolate state into separate state files. Think of them as named slots.

```bash
terraform workspace new staging
terraform workspace new prod
terraform workspace list          # * marks active
terraform workspace select prod
terraform apply -var-file=prod.tfvars
```

Inside your config, `terraform.workspace` gives the current workspace name — useful for naming resources:

```hcl
resource "local_file" "config" {
  filename = "${path.module}/output/${terraform.workspace}-config.txt"
  content  = "workspace = ${terraform.workspace}\n"
}
```

**When workspaces work well:** small teams, identical infra topology across envs, cheap resources, nothing stateful that can't tolerate an accidental cross-env apply.

**Where workspaces break down:** when envs diverge (prod has more replicas, different networking topology), because your `.tf` files have to handle all env variants via conditionals and `terraform.workspace` checks — which turns into spaghetti. Also: workspaces don't isolate backend credentials, so a `workspace select prod` + `apply` while configured with prod credentials is a footgun.

### Directory-per-environment

Each environment is a fully separate Terraform root:

```
infra/
  dev/
    main.tf
    terraform.tfvars
    backend.tf            # separate state bucket prefix
  staging/
    main.tf
    terraform.tfvars
    backend.tf
  prod/
    main.tf
    terraform.tfvars
    backend.tf
```

**Advantages:** full isolation — a `terraform apply` in `infra/dev/` cannot touch prod state. Each directory can drift to match its env. Credentials can be per-directory via `.envrc` or CI environment.

**Disadvantages:** duplication. A change to `main.tf` logic must be copied to three directories. Fix: extract shared logic into a local module and call it from each env directory.

### Terragrunt

Terragrunt is a thin HCL wrapper that adds DRY configuration across modules. It handles the "copy main.tf three times" problem by letting you define a root config once and override per-env:

```
infra/
  terragrunt.hcl           # shared backend config, provider defaults
  _modules/
    network/
  dev/
    network/
      terragrunt.hcl       # calls ../_modules/network with dev vars
  prod/
    network/
      terragrunt.hcl       # same module, prod vars
```

Terragrunt is worth learning if you're managing more than ~3 environments or a multi-account AWS setup. For a single-team, 2-env setup, directory-per-env with a shared module is usually sufficient.

**Decision rule:**

| Pattern | Use when |
|---------|---------|
| Workspaces | ≤ 2 envs, identical topology, low stakes |
| Directory-per-env | envs diverge, need credential isolation, small team |
| Terragrunt | 3+ envs, multi-region, large team, DRY across many modules matters |

---

## -target — the escape hatch and why to avoid it

`-target` restricts a plan/apply to one or more specific resources:

```bash
terraform apply -target=local_file.config -target=random_id.token
```

It feels useful when you want to "just update this one thing." The problem: Terraform's dependency graph means applying a resource out of order can leave state inconsistent. The next full apply will see a state that doesn't match what Terraform's plan expected, and you may get unexpected changes or errors.

Use `-target` only:
1. To bootstrap a chicken-and-egg dependency (e.g. the VPC must exist before the subnet, but your config defines both and the subnet's CIDR depends on the VPC's output before it exists in state)
2. As a one-time surgical intervention in an incident, not as a routine workflow

After any `-target` apply, run a full `terraform plan` (no `-target`) to confirm there is no residual drift.

---

## fmt and validate

These are pre-apply hygiene — run them in CI before anything else.

```bash
terraform fmt                     # reformat .tf files to canonical style
terraform fmt -recursive          # recurse into subdirectories
terraform fmt -check              # exit 1 if any file is not formatted (CI gate)
terraform fmt -diff               # show diff of what would change

terraform validate                # check syntax + provider schema (no network calls)
```

`validate` runs entirely offline — it doesn't call providers or read state. It catches type errors, missing required arguments, and unknown resource types. It does **not** catch logical errors (wrong CIDR, missing IAM permissions) — that's what `plan` is for.

Make these two commands the first steps of any CI pipeline.

---

## Terraform in CI

The safe CI pattern: **plan on PR, apply on merge, use a saved plan file** to guarantee what was reviewed is what executes.

```
┌──── PR opened ──────────────────────────────────────────────────────┐
│                                                                     │
│  terraform fmt -check          # fail fast if style is wrong        │
│  terraform validate            # fail fast on schema errors         │
│  terraform plan -out=tfplan    # generate + save plan               │
│  (post plan output as PR comment)                                   │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
              │
              │  PR reviewed and merged
              ▼
┌──── merge to main ──────────────────────────────────────────────────┐
│                                                                     │
│  terraform apply tfplan        # execute EXACTLY the reviewed plan  │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### Saved plan + drift window

The plan file is a snapshot at plan time. If someone applies a manual change to the infra between the PR plan and the merge apply, the saved plan is now stale. Terraform will error with a conflict. The correct response: re-run the plan (which will now reflect the drift), review again, apply.

This is a feature, not a bug — the error prevents you from blindly applying a plan against an infra state that no longer matches what was reviewed.

### CI credential handling

Providers need credentials to call APIs. The pattern:

```bash
# In your CI environment, set via secrets / env injection:
export TF_VAR_db_password="${{ secrets.DB_PASSWORD }}"

# For provider auth, prefer environment variables:
# AWS: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_REGION
# GCP: GOOGLE_CREDENTIALS (service account JSON)
# Generic: TF_VAR_* for any variable
```

Never commit credentials or plaintext secrets to any `.tf` or `.tfvars` file. The saved plan binary also captures variable values — if your plan file is stored as a CI artifact, ensure the artifact store is access-controlled.

A minimal GitHub Actions pattern for the local-provider challenges in this course:

```yaml
jobs:
  terraform:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: "1.9.0"
      - run: terraform fmt -check
        working-directory: infra/
      - run: terraform validate
        working-directory: infra/
      - run: terraform plan -out=tfplan
        working-directory: infra/
      - run: terraform apply tfplan
        working-directory: infra/
        if: github.ref == 'refs/heads/main'
```

---

## Debugging Workflow & Environments

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `apply` makes unexpected changes that weren't in the `plan` output you reviewed | Applied without a saved plan file; something changed between plan and apply (drift, or another operator applied manually) | Always use `-out=tfplan` + `terraform apply tfplan`. If drift is detected at apply time, Terraform errors — re-plan and review again before applying |
| Resources land in the wrong environment (prod resource created from dev workspace) | Active workspace is wrong | `terraform workspace show` before every apply; add an assertion: `if [ "$(terraform workspace show)" != "$EXPECTED_WS" ]; then exit 1; fi` |
| `terraform apply` in CI errors with `No value for required variable` | CI environment doesn't have `TF_VAR_*` variables set, or `-var-file` path is wrong | Check which variables lack defaults; verify CI secret injection; print `terraform workspace show` and env vars at job start (redact secrets) |
| `Error: the plan file is incompatible with the current state` | State was modified between plan and apply (manual apply, another pipeline ran, someone used `-target`) | Re-run the full plan, review the new diff, then apply |
| CI plan output shows no changes but infra is visibly wrong | Real state diverged from Terraform state (manual console changes, drift) | Run `terraform plan -refresh-only` to see what Terraform would import to reconcile; then decide to import or re-apply |
| `workspace select` succeeds but apply still targets old env | Remote backend configuration for workspace not picking up env-specific values; tfvars not passed | Confirm `terraform workspace show` output + ensure `-var-file` for the correct env is in the apply command |

> **War story.** Our team maintained two workspaces — `staging` and `prod` — on a shared Terraform Cloud backend. One Friday a senior engineer ran `terraform apply -var-file=prod.tfvars` with the intent to promote a change. The apply succeeded. On Monday, monitoring alerted that prod had zero load balancer health checks. Investigation: the engineer's local shell had `terraform workspace select staging` from a test earlier that week. The apply landed on the staging workspace with prod's tfvars — staging got prod-sized resources, and prod never received the intended change. It looked fine because it was staging, and staging had been unusually quiet. The CI pipeline hadn't caught it because it ran with the correct workspace. We added a mandatory `terraform workspace show` assertion to every apply script the next day: if `$TF_WORKSPACE` (set by CI) doesn't match the current workspace, exit 1. Context confusion in Terraform workspaces is exactly as dangerous as context confusion in kubectl — silent, and the blast radius is proportional to what you're running.

---

## Checkpoint

You're solid on workflow and environments when you can, without looking anything up:

1. Describe the three steps `terraform plan` takes and what it produces.
2. Explain the difference between `terraform apply` (no args) and `terraform apply tfplan` — why does it matter for CI?
3. Name all six variable sources in precedence order.
4. State when you would choose workspaces vs directory-per-env vs Terragrunt, in one table row per option.
5. Reproduce the `-target` escape hatch, state the one legitimate use case, and name the step you must run after any `-target` apply.
6. Write the two CI steps that must run before `plan`, and what each one catches.
7. Explain what "plan file is incompatible with current state" means and how to resolve it.
8. State the one-line shell assertion you add to every apply script to prevent workspace confusion.

➡ Next up: **Provisioners, Secrets & Good Practice** — when provisioners are actually the wrong tool, handling secrets without leaking them to state, and the testing and practices checklist that makes a Terraform codebase trustworthy.
