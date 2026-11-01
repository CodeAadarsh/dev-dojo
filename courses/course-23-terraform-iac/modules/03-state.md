# State: The Heart of Terraform

> **Module 03 · Course 23** — Remove the state file and Terraform becomes a script that creates duplicate resources on every run. State is the mechanism that makes the declarative model work: it records what Terraform created so the engine can diff desired vs actual. This module covers what state is, why it behaves the way it does, and how to handle the four ways it can go wrong: drift, stuck locks, lost state, and secrets baked in.

---

## What state is and why it exists

Terraform cannot query every provider API in real time during `plan` to know what already exists. Even if it could, providers don't always expose every attribute via GET — some attributes are write-only, some are only known at creation time, some are too expensive to read on every plan. State solves all three problems:

```
┌────────────────────────┐      plan      ┌────────────────────────────┐
│   desired state        │  ──────────►   │  execution plan (diff)      │
│   (.tf files)          │               │  + create A                 │
└────────────────────────┘               │  ~ update B                 │
                                         │  - destroy C                │
┌────────────────────────┐               └────────────────────────────┘
│   known state          │  ──────────►          ▲
│   (terraform.tfstate)  │  (what exists,         │
└────────────────────────┘   per Terraform)       │
                                                  │ apply writes new state
                                         ┌────────┴───────────────────┐
                                         │   real infrastructure       │
                                         │   (provider APIs / cloud)   │
                                         └────────────────────────────┘
```

State records, for each managed resource:
- The **resource address** (`aws_instance.web`)
- The **provider** that manages it
- Every attribute — both the ones you set and the computed ones Terraform read back after creation
- The **resource ID** the provider uses (the handle for update/destroy API calls)

Without the ID, Terraform cannot issue an update or delete call. Without the attributes, it cannot compute a diff. State is not a cache — it is a requirement.

---

## The state file

`terraform.tfstate` is a JSON file:

```json
{
  "version": 4,
  "terraform_version": "1.6.0",
  "serial": 12,
  "lineage": "a3b4c5d6-...",
  "outputs": {
    "file_path": {
      "value": "/tmp/hello.txt",
      "type": "string"
    }
  },
  "resources": [
    {
      "mode": "managed",
      "type": "local_file",
      "name": "greet",
      "provider": "provider[\"registry.terraform.io/hashicorp/local\"]",
      "instances": [
        {
          "schema_version": 0,
          "attributes": {
            "content": "Hello!\n",
            "filename": "/tmp/hello.txt",
            "id": "sha1:abc123..."
          }
        }
      ]
    }
  ]
}
```

The `serial` increments on every write. The `lineage` is a UUID assigned at creation — two state files with different lineages are from different workspaces (Terraform refuses to merge them). These two fields together mean Terraform can detect concurrent writes even without a distributed lock: if two processes read `serial=12`, both compute `serial=13`, and one writes it while the other still holds `serial=12`, the second write is rejected.

**Never edit state manually.** Use the `terraform state` subcommands or `import`. A manual edit that corrupts the JSON or mismatches a resource ID will cause `apply` to fail in opaque ways — at best a parse error, at worst silently orphaned resources.

---

## `terraform plan` as a diff engine

`plan` has three phases:

1. **Refresh** — Terraform calls each provider's READ operation to get the current attribute values for every resource in state. The result is a **refreshed state** held in memory (not written to disk yet unless you pass `-out=`).
2. **Diff** — the engine compares refreshed state against the desired state in `.tf` files. For each resource it determines: no-op, create, update, replace (destroy+create), or destroy.
3. **Output** — the plan is printed. If you pass `-out=plan.tfplan`, it's serialized to disk for deterministic apply.

```bash
terraform plan                    # read-only, no changes
terraform plan -out=plan.tfplan   # save for later apply
terraform show plan.tfplan        # human-readable plan from the saved file
terraform apply plan.tfplan       # apply exactly this plan, no re-plan
```

The saved plan is the gold standard for production applies: plan in PR review, apply the saved file. Applying without a saved plan re-runs plan at apply time, which means a change merged between plan and apply can silently appear.

> **`plan` is NOT read-only with `-refresh=false`.** By default, `plan` calls the provider's read operations (the refresh phase). In large environments with hundreds of resources this takes minutes. `-refresh=false` skips the refresh — plan is now a pure diff between `.tf` files and the *last recorded state*, ignoring real-world changes. Use it for speed in dev; never in production where drift is possible.

---

## Drift — out-of-band changes

Drift occurs when the real infrastructure diverges from the state Terraform holds. Common causes:
- A teammate ran `aws ec2 modify-instance-attribute` directly in the console
- An auto-scaling event changed a resource
- A cloud provider updated a default attribute
- Terraform's apply partially failed and left resources in an in-between state

Detect drift:

```bash
# plan refreshes by default — drift shows as unexpected changes
terraform plan

# explicit refresh-only run (Terraform 1.1+)
terraform apply -refresh-only
# shows what changed in the real world, proposes to update state to match
# does NOT change infrastructure — only updates state to reflect reality

# the old command (Terraform < 1.1)
terraform refresh   # deprecated but still functional
```

The critical distinction:
- `apply -refresh-only` → update state to match reality, leave infrastructure alone
- `apply` → update infrastructure to match `.tf` files, update state accordingly

When you see unexpected changes in `plan` that you know are legitimate (a colleague's hotfix), use `apply -refresh-only` to absorb them into state before the next `apply`. If you apply without doing this, Terraform will revert the hotfix.

---

## Remote state and locking

Local state (`terraform.tfstate` on disk) is fine for solo experiments. For a team, it's a disaster:

| Problem | Local state | Remote state |
|---------|------------|-------------|
| Two engineers apply simultaneously | Silently race, one silently overwrites | Backend lock prevents concurrent apply |
| State lost if the machine is lost | All managed resources become untracked | State is in durable object storage |
| State version history | Manual backups only | Every write is versioned (S3 versioning, GCS generations) |
| CI/CD can access state | Only if state is committed to git (a security disaster) | CI reads state from the backend with credentials |

Configure a remote backend in the `terraform` block:

```hcl
terraform {
  backend "s3" {
    bucket         = "my-team-tfstate"
    key            = "services/api/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-state-lock"
    encrypt        = true
  }
}
```

After changing the backend, `terraform init` migrates local state to the remote backend. For Terraform Cloud / HCP Terraform:

```hcl
terraform {
  cloud {
    organization = "my-org"
    workspaces {
      name = "api-production"
    }
  }
}
```

### Locking

When a backend supports locking (S3+DynamoDB, GCS, Terraform Cloud), `terraform apply` acquires a lock before writing state and releases it on completion. The lock record contains: who holds it, when it was acquired, and the operation type.

```bash
# You'll see this if someone else is applying
Error: Error acquiring the state lock
  Lock Info:
    ID:        a4b5c6d7-...
    Path:      my-team-tfstate/services/api/terraform.tfstate
    Operation: apply
    Who:       alice@corp.com
    Created:   2026-10-15 14:23:01.123456789 +0000 UTC
    Info:
```

This is correct behaviour — wait for the other apply to finish.

---

## Importing existing resources

Resources created outside Terraform (manually, by another tool, or by another Terraform config) can be brought under management with `import`:

```bash
# Classic import (Terraform < 1.5)
terraform import aws_s3_bucket.existing my-existing-bucket-name

# Import block (Terraform >= 1.5, preferred — declarative, plan-visible)
import {
  to = aws_s3_bucket.existing
  id = "my-existing-bucket-name"
}
```

After import, the resource is in state but `.tf` files may not match the actual attributes. Run `terraform plan` — it shows the diff between state and config. Adjust your `.tf` until `plan` reports no changes. Only then is the import complete.

The `id` value is provider-specific — it's the same string the provider uses as the resource's primary key. Check the provider docs under "Import" for the exact format (sometimes it's a single ID, sometimes it's a composite like `region/resource-id`).

```bash
# Generate config from imported state (Terraform 1.5+)
terraform plan -generate-config-out=generated.tf
# writes HCL for the imported resource — starting point, not final answer
```

---

## State surgery — mv, rm, and why it's dangerous

The `terraform state` subcommands let you manipulate state without changing infrastructure. Use sparingly:

```bash
# Move a resource to a new address (rename, module restructuring)
terraform state mv aws_instance.web aws_instance.api

# Remove a resource from state without destroying it
terraform state rm aws_instance.legacy

# List all resources in state
terraform state list

# Show the state record for one resource
terraform state show aws_s3_bucket.existing

# Pull state from remote backend (JSON to stdout)
terraform state pull > backup.tfstate

# Push a local state file to the remote backend (danger zone)
terraform state push backup.tfstate
```

`state mv` changes the resource address in state — useful when you rename a resource in `.tf` files (otherwise Terraform sees a destroy + create). After `mv`, run `plan` and confirm it shows no changes.

`state rm` removes the resource from Terraform's tracking. The real infrastructure continues to exist and is now **unmanaged**. Use this when you want to take a resource out of Terraform management (e.g. handing it to another team), not as a workaround for a failing destroy.

`state push` overwrites the remote state entirely. The only legitimate use is restoring from a backup after state corruption — and even then, run `terraform plan` immediately after to confirm the state matches reality.

> **State surgery checklist before any `state` write command:**
> 1. `terraform state pull > before.tfstate` — take a backup
> 2. Confirm you are on the right workspace and context
> 3. Run the command
> 4. `terraform plan` — confirm the result is a no-op (or only the intended change)
> 5. Never `state push` a file edited manually

---

## Debugging State

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `plan` shows unexpected destroy+create for an unchanged resource | Attribute that forces replacement changed (provider-specific); or resource was recreated outside Terraform | Read `plan` carefully for `# forces replacement`; if the resource was manually recreated, `state rm` + `import` |
| `Error: Error locking state: lock file already exists` (local) or DynamoDB lock held | Terraform crashed during a previous apply; lock was not released | Verify no apply is running; `terraform force-unlock <lock-id>` — only after confirming no apply is in progress |
| Two workspaces have the same state (forked state) | `state push` was run with a stale file; or the same backend key was used for two environments | Reconcile by determining which is authoritative; use `state pull` on both, diff them, and `import` or `state mv` to merge; never overwrite without a backup |
| `terraform plan` says "no changes" but the resource is clearly different in the console | Refresh was skipped (`-refresh=false`) or the attribute is not tracked in state | Remove `-refresh=false`; run `apply -refresh-only` to re-sync state |
| Sensitive values appear in `terraform plan` output | Terraform detected a sensitive value in a non-sensitive context | Audit which resource exposes the value; add `sensitive = true` to the output; for provider-level sensitive attributes, the provider marks them automatically in newer versions |
| `Error: state snapshot was created by a newer version of Terraform` | State was written by a higher version of the CLI than the one running now | Upgrade the local CLI: `tfenv install <version>` |

### Diagnosing a stuck lock

```bash
terraform plan
# Error: Error acquiring the state lock
#   Lock Info:
#     ID: c7d8e9f0-...
#     Created: 2026-10-20 09:00:00 +0000 UTC

# Confirm no Terraform process is running
ps aux | grep terraform

# Check CI — is a job running?
# If truly stale (crash, killed job):
terraform force-unlock c7d8e9f0-...
# WARNING: only run this if you are CERTAIN no apply is in progress
# A false unlock on a live apply corrupts state
```

For S3/DynamoDB backends, the lock record is in DynamoDB. You can inspect it directly:

```bash
aws dynamodb get-item \
  --table-name terraform-state-lock \
  --key '{"LockID":{"S":"my-team-tfstate/services/api/terraform.tfstate-md5"}}'
```

Delete the DynamoDB item directly only if `force-unlock` fails — same caveat applies: only if you are certain no apply is running.

### Dealing with drift in production

```bash
# Step 1: understand what drifted
terraform plan 2>&1 | tee drift-report.txt
grep -E '(must be replaced|will be updated|will be destroyed)' drift-report.txt

# Step 2: decide — absorb the drift or revert it
# Absorb (accept the manual change as the new truth):
terraform apply -refresh-only

# Revert (bring the real world back to the Terraform config):
terraform apply

# Step 3: find the root cause
# Who changed it?  → CloudTrail / Audit Logs
# Why was it changed manually?  → On-call incident? Workaround?
# Prevent recurrence → enforce IaC via SCPs / Org Policies that deny
#                      console changes to managed resources
```

> **War story.** An engineering team I knew ran Terraform for their entire GCP project — VPC, GKE, Cloud SQL, IAM. One Friday a DBA made an emergency "hotfix" to the Cloud SQL instance's flags (max_connections) through the console without telling anyone. The following Monday someone ran `terraform apply` for an unrelated change to IAM roles. The apply plan showed the IAM change and — buried seven lines down — "will update Cloud SQL instance: remove flag max_connections". Nobody noticed. The apply ran. The flag reverted. By Tuesday afternoon, the database was dropping connections under load again and it took three hours to correlate the timeline to the Terraform apply. The fix the team adopted: always run `terraform plan -out=plan.tfplan`, post the plan output as a CI artifact, and require a second reviewer to read the plan before `apply` runs. Terraform will not protect you from applying a plan you didn't read.

---

## Checkpoint

You're ready for Module 04 when you can, without looking anything up:

1. Explain what Terraform state records and why the engine cannot function without it.
2. Describe the three phases of `terraform plan` and what happens in each.
3. State the difference between `apply -refresh-only` and `apply`, and when you'd use each.
4. Configure an S3 backend with DynamoDB locking in a `terraform` block.
5. Import an existing resource using both the CLI `import` command and a declarative `import {}` block.
6. Explain when `state rm` is the right tool and when it is a dangerous workaround.
7. Diagnose a stuck state lock and list the conditions under which `force-unlock` is safe.
8. Describe how drift enters a Terraform-managed environment and name two ways to respond to it.
9. Explain why `sensitive = true` on an output does not protect the value in state, and what the real mitigation is.

➡ Next up: **Modules & Composition** — how to package configs for reuse, when modularization pays off, and the path issues and over-abstraction traps that catch everyone the first time.
