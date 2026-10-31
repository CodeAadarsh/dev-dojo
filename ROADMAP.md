# KUBE-DOJO — Course Roadmap

A living plan for the dojo. The platform is a pure content reader, so a course is
"shipped" the moment its folder (with `course.json` + `modules/` + `challenges/`)
lands under `courses/`. See [CONTENT_SPEC.md](./CONTENT_SPEC.md) for the contract.

> **Verifier models.** Kubernetes courses verify against a disposable `kind`
> cluster (`kubectl`). Non-K8s courses (code/AI) verify a **local artifact** —
> `setup.sh` scaffolds a project under `~/.kube-dojo-work/<slug>`, `verify.sh`
> runs pytest / curls your app / checks output. "Bridge" challenges end by
> containerizing and deploying to `kind`.

---

## Status snapshot (2026-11-01)

**21 courses live · 137 modules · 150 challenges — all complete.**

| # | Course | Modules | Challenges | State |
|---|--------|:---:|:---:|-------|
| 1 | Ops + Security | 8 | 18 | ✅ |
| 2 | Production SRE | 7 | 7 | ✅ |
| 3 | Attack & Defend (CTF) | 7 | 7 | ✅ |
| 4 | Cert: CKA·CKAD·CKS | 7 | 6 | ✅ |
| 5 | Internals, Cluster & Repo | 8 | 6 | ✅ |
| 6 | Observability (LGTM) | 6 | 6 | ✅ |
| 7 | Networking & Service Mesh | 6 | 6 | ✅ |
| 8 | Stateful Workloads & Data | 6 | 6 | ✅ |
| 9 | Platform Engineering | 6 | 7 | ✅ |
| 10 | Backend Engineering (SDE 1→3) | 6 | 6 | ✅ |
| 11 | Generative AI: RAG & Applied AI | 6 | 6 | ✅ |
| 12 | Python Flask in Production | 6 | 6 | ✅ |
| 13 | DSA for Tier-1 Interviews | 6 | 8 | ✅ |
| 14 | System Design: SDE-2 → SDE-3 | 6 | 8 | ✅ |
| 15 | FastAPI in Production | 6 | 11 | ✅ |
| 16 | Security & Authentication | 6 | 6 | ✅ |
| 17 | The LGTM Stack, Operated | 6 | 6 | ✅ |
| 18 | PostgreSQL: Internals & Practice | 7 | 6 | ✅ |
| 19 | Redis: Internals & Practice | 7 | 6 | ✅ |
| 20 | Database Engineering (Complete) | 7 | 6 | ✅ |
| 21 | Data Science with Python | 7 | 6 | ✅ |

---

## Milestone 0 — Finish what's started

✅ **Done (2026-11-01)** — Courses 11 (GenAI) and 12 (Flask) are now complete, 6 challenges each. All 17 courses are fully built.

---

## Milestone 1 — Career track (highest priority for the SDE-2 / Tier-1 goal)

> ✅ **Courses 13 & 14 are now SHIPPED** (full: 6 modules + 8 challenges each). Course 15 remains.

| # | Course | Difficulty | Est. | Verifier | Scope |
|---|--------|-----------|------|----------|-------|
| 13 | **DSA for Tier-1 Interviews** ✅ | Int → Adv | 25–40 h | local (pytest) | the 15 patterns (two-pointers, sliding window, heaps, graphs, DP…), timed drills, complexity analysis; each challenge is a judged problem |
| 14 | **System Design (SDE-2 → SDE-3)** ✅ | Advanced | 18–24 h | local / discovery | design a URL shortener, feed, rate limiter, chat, payment ledger; rubric self-checks + capacity math |
| 15 | **The SDE-2 Interview Loop** | Int → Adv | 10–14 h | discovery | coding + design + behavioral prep, company-specific (Grafana, Uber, Atlassian, Razorpay…), negotiation |

## Milestone 2 — Cloud, IaC & delivery

| # | Course | Difficulty | Est. | Verifier | Scope |
|---|--------|-----------|------|----------|-------|
| 16 | **Terraform & IaC** | Int → Adv | 12–16 h | local + kind | HCL, state, modules, plan/apply, drift, testing; provision against a local provider |
| 17 | **Managed Kubernetes (EKS/GKE/AKS)** | Advanced | 10–14 h | reading + kind | cloud IAM, node pools, LBs, autoscaling, cost — concepts you can't do on kind |
| 18 | **CI/CD Pipelines** | Int → Adv | 12–16 h | local + kind | GitHub Actions, Argo Workflows, Tekton, progressive delivery, supply-chain gates |

## Milestone 3 — Go & cloud-native development

| # | Course | Difficulty | Est. | Verifier | Scope |
|---|--------|-----------|------|----------|-------|
| 19 | **Go for Cloud-Native** | Advanced | 18–24 h | local + kind | Go fundamentals → build a real controller/operator with kubebuilder; client-go, informers, reconcile |

## Milestone 4 — Data & AI (AI Core team relevance)

| # | Course | Difficulty | Est. | Verifier | Scope |
|---|--------|-----------|------|----------|-------|
| 20 | **Data Engineering** | Advanced | 18–24 h | local + kind | Kafka deep, Airflow DAGs, batch vs stream, schema/CDC, the lakehouse |
| 21 | **MLOps** | Adv → Insane | 18–24 h | kind | model serving (KServe), feature stores, vector DBs at scale, pipelines, drift |
| 22 | **LLMOps & Agentic Systems** | Adv → Insane | 16–22 h | local + kind | builds on course 11: eval pipelines, guardrails at scale, multi-agent orchestration, serving economics |

## Milestone 5 — SRE & security deepening

| # | Course | Difficulty | Est. | Verifier | Scope |
|---|--------|-----------|------|----------|-------|
| 23 | **Chaos Engineering** | Advanced | 12–16 h | kind | Chaos Mesh, fault injection, GameDays, steady-state hypotheses |
| 24 | **Performance Engineering** | Advanced | 12–16 h | local + kind | k6 load testing, profiling (pprof/flamegraphs), tuning, capacity |
| 25 | **Supply-Chain Security** | Adv → Insane | 12–16 h | kind | SLSA, cosign/sigstore signing, SBOMs, admission enforcement, trivy deep |
| 26 | **Secrets & Zero Trust** | Advanced | 12–16 h | kind | Vault, External Secrets Operator, SPIFFE/SPIRE, workload identity |

## Milestone 6 — Full-stack (primary stack)

| # | Course | Difficulty | Est. | Verifier | Scope |
|---|--------|-----------|------|----------|-------|
| 27 | **Next.js in Production** | Int → Adv | 14–18 h | local + deploy | App Router, RSC, caching, auth, edge, observability, ship to Vercel/kind |
| 28 | **TypeScript/Node Backend at Scale** | Advanced | 14–18 h | local + kind | type-safe APIs, Drizzle/Prisma, queues, testing, perf |

---

## Suggested next 3 (recommended order)

1. **Finish courses 11 & 12** (Milestone 0) — small, completes what exists.
2. **Course 13 — DSA for Tier-1 Interviews** — the biggest lever on the Jun-2027 SDE-2 goal.
3. **Course 14 — System Design** — the SDE-2/SDE-3 differentiator; pairs with the DSA course.

## Build cadence (budget-aware)

The Hyperspace proxy caps spend at **€100/day** (resets UTC midnight). A full course
(~6 modules + ~6 challenges) on `sonnet` runs ~1M tokens. Practically: **2–3 full
courses per budget-day** in waves, verifying each wave (file completeness + flag-hash
integrity + `bash -n`) before committing. Author on `sonnet`; reserve `opus` for a
final polish pass if desired.

## How to add a course

1. `courses/course-NN-slug/course.json` (id, slug, order, difficulty, estHours, prereqs, tags, description).
2. `modules/NN-topic.md` — each with a `## Debugging` section + `## Checkpoint`.
3. `challenges/NN-slug/` — `challenge.json`, `brief.md`, `setup.sh`, `verify.sh` (verifier) or discovery, `solution.md`, `hints.json`, `flag.sha256`.
4. Flip `status` to `available` once it has ≥1 module and ≥1 challenge. It appears in the UI automatically.
