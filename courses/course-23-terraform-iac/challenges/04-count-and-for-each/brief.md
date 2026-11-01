# Iterate With for_each

A platform team owns twelve microservices. Until last week they provisioned each service's config manifest by hand — twelve separate `resource "local_file"` blocks, copy-pasted and renamed. A PR comment landed: *"This is not IaC, this is YAML with extra steps. Every time we add a service someone forgets to update three of these."*

Your job: replace the brittle copy-paste pattern with a single `for_each` block that drives all resources from a map.

## Context

`setup.sh` plants a starter project in your work directory:

```
~/.kube-dojo-work/04-count-and-for-each/
├── main.tf       # locals map + stubbed local_file resource
└── outputs.tf    # service_count and service_files outputs
```

## Prerequisites

```bash
cd ~/.kube-dojo-work/04-count-and-for-each
terraform init
```

Terraform 1.5+ and internet once for provider download (hashicorp/local ~2.4).

## Mission

Edit `main.tf` so that `terraform apply` creates **exactly three files** under `output/`, one per entry in `locals.services`, each with the correct per-key content:

| File | Required content (first two lines) |
|------|------------------------------------|
| `output/auth-service.txt` | `Service: auth-service` on line 1 |
| `output/payment-service.txt` | `Service: payment-service` on line 1 |
| `output/catalog-service.txt` | `Service: catalog-service` on line 1 |

The `verify.sh` checks:

1. All three files exist under `output/`.
2. Each file's first line is `Service: <key>` with the exact key from the map.
3. Each file's second line is `Description: <value>` with the exact value from the map.
4. The `service_count` output equals `3`.

The stub sets `for_each = {}` which creates zero files. Replace that with `local.services` and fill in `filename` and `content` using `each.key` and `each.value`.

## Why for_each beats count for maps

`count` gives you indexed replicas (`resource[0]`, `resource[1]`). Adding a service in the middle reindexes everything — Terraform sees `resource[1]` as "was payment, now catalog" and destroys + recreates. With `for_each` the key is stable; adding `"billing-service"` touches only the new resource. The difference matters when the resource is a database or a DNS record with downtime cost.

```
# count — fragile index
resource "local_file" "manifest" {
  count    = length(local.services_list)
  filename = "output/${local.services_list[count.index]}.txt"
}

# for_each — stable key, idempotent
resource "local_file" "manifest" {
  for_each = local.services
  filename = "output/${each.key}.txt"
}
```

## Verify

```bash
bash courses/course-23-terraform-iac/challenges/04-count-and-for-each/verify.sh
```

All checks green → flag printed.
