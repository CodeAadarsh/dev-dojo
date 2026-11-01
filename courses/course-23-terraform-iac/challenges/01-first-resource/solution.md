# Solution — Your First Resource

Complete `main.tf`:

```hcl
terraform {
  required_providers {
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

resource "local_file" "greeting" {
  filename = "${path.module}/output/hello.txt"
  content  = "Hello, Terraform!\n"
}
```

## Why each piece is required

**`path.module`** is a built-in Terraform expression that resolves to the absolute path of the directory containing the `.tf` file. Using it makes `filename` an absolute path regardless of which directory you invoke `terraform` from. A bare `"output/hello.txt"` works when you `cd` to the work directory first, but fails silently if you run terraform from a parent directory — the file lands somewhere else and the verifier finds nothing.

**`content = "Hello, Terraform!\n"`** — HCL double-quoted strings interpret escape sequences exactly like Go: `\n` becomes a newline character. This is intentional — it means the file ends with a proper newline, which is the POSIX convention for text files. For multi-line content use the heredoc syntax (`<<-EOT ... EOT`); for single values like this a quoted string is idiomatic.

**`required_providers` block** — Terraform has no built-in knowledge of providers. Even `hashicorp/local` must be declared so `terraform init` knows what to download. Omit it and init errors with `Missing required provider`. The `version = "~> 2.5"` constraint means "2.5 or any later patch within the 2.x series." Commit `.terraform.lock.hcl` to source control to pin the exact provider hash and make runs reproducible across machines.

**Resource label `"greeting"`** — the second string in `resource "local_file" "greeting"` is the local name. It scopes the resource to this module: `local_file.greeting.filename` is how you reference the actual created path in outputs or other resources.

## Apply and verify

```bash
cd ~/.kube-dojo-work/01-first-resource
terraform init
terraform plan          # inspect the diff before committing
terraform apply -auto-approve
cat output/hello.txt    # Hello, Terraform!
bash courses/course-23-terraform-iac/challenges/01-first-resource/verify.sh
```

## Hardening preview

In production, never commit `terraform.tfstate` to git — it contains plaintext secret values and provider auth tokens. The standard pattern is a **remote backend** (S3 + DynamoDB for AWS, GCS for GCP) that stores state encrypted at rest and provides locking via a lease so two engineers can't run `apply` simultaneously and corrupt state. For this lab the local backend is fine, but internalise the rule early.
