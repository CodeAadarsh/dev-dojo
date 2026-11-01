# ⛩ DevDojo

A local-first, **hands-on engineering dojo**: 21 courses spanning Kubernetes,
databases, backend, security and AI. Browse courses in a web UI, read the guide,
then do the real work in **your own terminal** — against a disposable `kind`
cluster, a throwaway Docker Postgres/Redis, or a plain Python project — and
capture the flag. HTB-style: every challenge ends in a `KUBE{…}` flag you *earn*
by making the system actually work.

The platform is a pure content **reader**, so courses span any domain — see
**[ROADMAP.md](./ROADMAP.md)** for what's shipped and what's planned.

```
dev-dojo/
├── platform/        the web app (Next.js) — courses, guides, flag submission, progress
├── labs/bootstrap/  scripts: kind, ArgoCD, ingress, metrics-server, monitoring, local registry
├── courses/         21 self-contained courses (K8s · backend · data · AI · security · interview)
└── CONTENT_SPEC.md  authoring contract   ·   ROADMAP.md  the course plan
```

### Courses (27 live)

| # | Course | Focus | Verifier |
|---|--------|-------|----------|
| 01 | Kubernetes Ops + Security ← **start here** | balanced ops + attack/defend | kind |
| 02 | Production SRE | reliability, autoscaling, SLOs | kind |
| 03 | Attack & Defend (CTF) | K8s offense → hardening | kind |
| 04 | Cert Prep: CKA · CKAD · CKS | timed exam drills | kind |
| 05 | Internals, Cluster & Repo Mgmt | control plane, etcd, registries | kind |
| 06 | Observability (LGTM) | Prometheus/Loki/Grafana/Tempo | kind |
| 07 | Networking & Service Mesh | CNI, Gateway API, Istio, mTLS | kind |
| 08 | Stateful Workloads & Data | StatefulSets, storage, backups | kind |
| 09 | Platform Engineering & DevEx | Helm, operators, policy, tenancy | kind |
| 10 | Backend Engineering (SDE 1→3) | APIs, data, caching, system design | local + kind |
| 11 | Generative AI: RAG & Applied AI | LLMs, embeddings, RAG, agents | local + kind |
| 12 | Python Flask in Production | app factory → deploy | local + kind |
| 13 | DSA for Tier-1 Interviews | 15 patterns, pytest-judged problems | local |
| 14 | System Design: SDE-2 → SDE-3 | framework + worked designs | local |
| 15 | FastAPI in Production | async APIs, Pydantic, pytest-judged | local + kind |
| 16 | Security & Authentication | all auth types + OWASP, hands-on | local + kind |
| 17 | The LGTM Stack, Operated | run Loki/Grafana/Tempo/Mimir | kind |
| 18 | PostgreSQL: Internals & Practice | MVCC, WAL, indexes, planner, tuning | local (Docker) |
| 19 | Redis: Internals & Practice | encodings, persistence, cluster, patterns | local (Docker) |
| 20 | Database Engineering (Complete) | storage engines → Raft, vendor-agnostic | local + Docker |
| 21 | Data Science with Python | NumPy → ML, leakage-aware, pytest-judged | local |
| 22 | Go for Cloud-Native | Go → build & deploy an operator | local + kind |
| 23 | Terraform & IaC | HCL, state/drift, modules (cloud-free) | local |
| 24 | MLOps | train → serve → monitor → deploy, pytest-judged | local + kind |
| 25 | CI/CD Pipelines | GitHub Actions, gates, progressive delivery | local + kind |
| 26 | Data Engineering | ETL/CDC → Kafka → Airflow → lakehouse | local |
| 27 | LLMOps & Agentic Systems | prompts, eval, guardrails, agents, serving | local + kind |

More courses (DSA, System Design, Terraform, Go, MLOps, …) are planned — see
[ROADMAP.md](./ROADMAP.md).

## Setup

```bash
git clone https://github.com/CodeAadarsh/dev-dojo.git
cd dev-dojo
```

**Always needed** (the platform): Node 20+ and `pnpm`.
**Per course, one of:**
- K8s courses (1–9, 17) → **Docker Desktop** + `kind` (`bash labs/bootstrap/install-kind.sh`) + `kubectl` + `helm`
- PostgreSQL / Redis / DB (18–20) → **Docker Desktop** only (challenges spin up throwaway containers)
- Code & data courses (10–16, 20–21) → **Python 3** (`pip install` per challenge brief); the deploy "bridge" challenges also use Docker + kind

Each challenge's brief lists exactly what it needs.

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
