# ⎈ KUBE-DOJO

An HTB-style, **local-first** learning platform for production Docker, Kubernetes
& ArgoCD. Browse courses in a web UI, read the guide, then do the real work in
**your own terminal** against a disposable `kind` cluster, and capture flags.

```
kube-dojo/
├── platform/        the web app (Next.js) — the "HTB UI": courses, guides, flag submission, progress
├── labs/bootstrap/  scripts to install kind, create the cluster, install ArgoCD/ingress
├── courses/         each course is its own self-contained repo of content + challenges
│   ├── course-01-ops-security/     Kubernetes Ops + Security  (balanced)   ← start here
│   ├── course-02-sre-production/    Production SRE
│   ├── course-03-security-ctf/      Attack & Defend (CTF)
│   └── course-04-cert-cka-ckad-cks/ Cert Prep: CKA · CKAD · CKS
└── CONTENT_SPEC.md  the contract for authoring courses/challenges
```

## Prerequisites

- **Docker Desktop** running (`open -a Docker`)
- `kubectl` and `helm` (you have them)
- `kind` — install with `bash labs/bootstrap/install-kind.sh`
- Node 20+ and `pnpm` (you have them)

## 1. Start the platform

```bash
cd platform
pnpm install          # first time only
pnpm dev              # http://localhost:4477
```

Open **http://localhost:4477**. Progress is stored locally in
`platform/.data/dojo.db` (single user, no login, fully offline).

## 2. Spin up your lab cluster

In a separate terminal, from the `kube-dojo` root:

```bash
bash labs/bootstrap/install-kind.sh      # once
bash labs/bootstrap/create-cluster.sh    # 3-node cluster named 'dojo'
bash labs/bootstrap/install-argocd.sh    # when a course needs GitOps
```

Reset anytime — the cluster is disposable:

```bash
bash labs/bootstrap/teardown.sh && bash labs/bootstrap/create-cluster.sh
```

## 3. Work a challenge

1. Pick a course → pick a challenge in the web UI.
2. Run its **setup** command (shown on the page) to plant the scenario.
3. Do the work in your terminal (`kubectl …`).
4. **Verifier** challenges: run the shown **verify** command — it checks your
   cluster and prints a flag on success.
   **Discovery** challenges: extract the hidden flag yourself.
5. Paste the `KUBE{…}` flag into the platform to mark it solved.

## Flags

Each challenge commits only `flag.sha256` (never the plaintext). The platform
hashes what you submit and compares — so the `courses/` repos can be public
without leaking answers.

## Adding your own content

See **[CONTENT_SPEC.md](./CONTENT_SPEC.md)**. Drop a folder in `courses/` with a
`course.json` and it appears automatically — the platform is just a reader.
