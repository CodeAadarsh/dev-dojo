# Your First Resource

A teammate just asked "why are we spending two weeks on Terraform?" — then watched a 9-hour outage caused by a hand-crafted security group nobody remembered creating. The entire incident review came down to: *the infra was not in code, so no one knew what was there*.

Your first step into IaC is the smallest possible one: tell Terraform to create a file on disk. One resource, one apply. You'll see exactly how Terraform reads HCL, plans a diff, and converges state — the same lifecycle you reuse for every IAM role, RDS instance, and EKS node group you declare later.

## Context

`setup.sh` plants a starter configuration in your work directory:

```
~/.kube-dojo-work/01-first-resource/
├── main.tf          # terraform + provider block declared; local_file stub to fill in
└── output/          # Terraform will create hello.txt here
```

## Prerequisites

Terraform 1.5+ on your `PATH`:

```bash
terraform version
```

## Mission

Fill in the `local_file` resource stub in `main.tf` so that after `terraform apply`:

1. The file `output/hello.txt` exists inside your work directory.
2. Its content is exactly `Hello, Terraform!` (with a trailing newline — use `\n` in the HCL string).

`verify.sh` runs `terraform init && terraform apply -auto-approve` for you. Write the correct HCL first, then call it.

### What verify checks

| Check | Expected |
|-------|----------|
| File exists | `~/.kube-dojo-work/01-first-resource/output/hello.txt` |
| File content | `Hello, Terraform!` |

## Why this matters

`local_file` is the "Hello World" of Terraform providers — no credentials, no cloud account, just the OS filesystem. The lifecycle is identical to a production resource:

| Phase | What happens |
|-------|-------------|
| `terraform init` | Downloads the provider plugin into `.terraform/`; writes `.terraform.lock.hcl` |
| `terraform plan` | Computes the diff between your code and current state |
| `terraform apply` | Executes the plan; writes `terraform.tfstate` |
| `terraform destroy` | Deletes every resource managed by this configuration |

Getting this right for a file means you already own the mental model. The only thing that changes for an EC2 instance is which provider you're talking to.

## Verify

```bash
bash courses/course-23-terraform-iac/challenges/01-first-resource/verify.sh
```

File created with exact content → flag printed.
