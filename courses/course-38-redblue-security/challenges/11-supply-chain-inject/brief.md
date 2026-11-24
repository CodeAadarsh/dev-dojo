# Challenge 11 — Supply Chain Inject

**Difficulty:** Hard | **Type:** Verifier | **Est. Time:** 60 min

---

## Situation

Your CI pipeline built two images yesterday and today. Something changed between them — and it wasn't your team's commit.

The images are:
- `dojo/app-clean:1.0` — yesterday's good build
- `dojo/app-infected:1.1` — today's suspicious build

A threat intel feed flagged `1.1` as potentially compromised. Your job:

1. **Identify** the injected package using SBOM diffing
2. **Remediate** — update the deployment to use the clean image
3. **Mark** the namespace as remediated

The verifier checks all three.

---

## Lab Setup

```bash
bash courses/course-38-redblue-security/challenges/11-supply-chain-inject/setup.sh
```

---

## What to Do

### Step 1 — Generate SBOMs

```bash
syft dojo/app-clean:1.0 -o spdx-json > clean.json
syft dojo/app-infected:1.1 -o spdx-json > infected.json
```

### Step 2 — Diff the package lists

Find the package present in `infected.json` but not in `clean.json`.

### Step 3 — Record your finding

```bash
kubectl create configmap sbom-diff-result \
  -n dojo-sec-supplychain \
  --from-literal=malicious_package=<package-name>
```

### Step 4 — Fix the deployment

Update the `app` deployment to use `dojo/app-clean:1.0`.

### Step 5 — Mark remediated

```bash
kubectl annotate namespace dojo-sec-supplychain dojo.supply-chain/status=remediated
```

---

## Verifier

```bash
bash courses/course-38-redblue-security/challenges/11-supply-chain-inject/verify.sh
```

---

## What You'll Learn

- SBOM generation with `syft` (SPDX + CycloneDX formats)
- Diffing SBOMs to detect injected dependencies
- Supply chain attack patterns (dependency confusion, typosquatting, inject-then-push)
- Admission control and image signing as preventive controls
