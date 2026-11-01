# LLMOps vs MLOps

> **Module 01 · Course 27** — If you have MLOps experience, your first instinct will be to reach for the existing playbook: version data, version models, monitor for drift. Most of that discipline still applies. The parts that don't are what will catch you in production.

MLOps matured around one core assumption: *your artifact is a trained weight file, and quality is a single number (accuracy, AUC, F1) on a held-out test set*. LLMs invalidate both halves of that assumption simultaneously, and the operational implications cascade from there.

---

## The six genuine differences

### 1. Prompts are artifacts

In classical ML, the inference code that calls a model is infrastructure plumbing — it doesn't materially affect what the model outputs. With LLMs, **the prompt is the product behavior**. A single-word change to a system prompt can shift tone, break structured-output parsing, or introduce hallucination in an edge case you hadn't considered.

Operationally this means prompts deserve the same treatment as source code: version control, change review, a staging environment, and rollback capability. A prompt that lives in a database column updated via an admin UI is the equivalent of deploying to production by SSH-editing a running binary. It will betray you at the worst possible moment.

```
classical ML                   LLMOps
────────────                   ───────
data → train → weight file     prompt template ────┐
model serves weights           few-shot examples ──┤──▶ model API ──▶ output
one artifact to version        model + version ────┤
                               params (temp/top-p)─┘
```

All four of those inputs jointly determine what the model returns. Changing any one without recording which one changed leaves you with untracked state in production.

### 2. Outputs are non-deterministic by default

Even at `temperature=0`, most commercial LLM APIs are *near*-deterministic, not *guaranteed* deterministic. At `temperature>0` — which covers almost every production chat or generation use case — the same prompt on successive calls returns measurably different outputs. This has three operational consequences:

- **Tests.** You cannot write `assert output == "the Eiffel Tower"`. You must assert semantic properties ("response mentions Paris", "JSON parses cleanly", "answer contains a date"), or use a rubric evaluated by a judge.
- **Regression.** A quality drop can look like random noise across a handful of runs. You need to evaluate over a *population* of outputs, not a single probe.
- **Debugging.** Repro is probabilistic. Log the input, the output, and the full call parameters on every single inference — not just on error.

### 3. There is no single accuracy number

A supervised classifier ships when it clears a threshold: *test accuracy 92.3%, above the 91% gate, approved to deploy*. Clear, binary, defensible.

An LLM in production might be accurate on factual recall, verbose on short questions, occasionally hallucinate company-specific acronyms, produce valid JSON 94.7% of the time, sometimes refuse legitimate requests, and leak an internal tool name in 0.3% of responses. Each of those is a separate metric. None of them is "accuracy."

This isn't a measurement annoyance — it means **you cannot declare an LLM "ready"** the way you declare a classifier "above threshold." You ship with a known failure profile, tracked metrics for each failure mode, and an alerting strategy. The decision to deploy is a risk-tolerance conversation, not a number crossing a line.

### 4. Eval is a first-class engineering concern

In classical ML, you split a labeled dataset and run the test set at the end of training. Once (or at each retraining cycle). Eval is a milestone, not a pipeline.

With LLMs, every prompt change, model version bump, and tool addition must be validated against a regression suite before hitting production. That means **eval infrastructure** — golden datasets, judge prompts, CI integration, trend tracking — is load-bearing, not optional. Teams that build eval as an afterthought have no baseline when something breaks. You are flying blind with no ground truth to regress against.

The correct mental model: eval is a production-grade service that runs on every merge to the prompt registry, every model pin update, and every schema change.

### 5. Cost and latency are product constraints, not just ops concerns

A 5% improvement in output quality that doubles your token spend per call is a **product decision**, not just an infra optimization. A model that answers correctly in 8 seconds is unacceptable for an interactive chat surface and completely fine for a nightly document pipeline.

Cost and latency belong in the product spec alongside quality metrics. The operational implication: you need a routing layer that can direct a "summarize this email" request to a small/cheap model and a "write the architecture rationale for this RFC" request to a larger one — and that routing decision is itself a measurable, tunable, versioned component of the system.

### 6. The surface is four-dimensional

| Dimension | What can change | Blast radius |
|-----------|-----------------|-------------|
| **Prompt** | template text, system role, few-shot examples | output quality, format, tone, safety |
| **Model** | provider, version, architecture | latency, cost, capability, refusal policy |
| **Parameters** | temperature, top-p, max_tokens, seed | output variance, length, reproducibility |
| **Tools / RAG context** | tool schema, retrieved chunks, chunking strategy | grounding accuracy, injection surface, hallucination rate |

Any of these can change independently. Any change can silently degrade quality. If you don't version all four and run your eval suite after every change, you have unverified state in production.

---

## The LLMOps perimeter

```
                ┌──────────────────────────────────────────────────┐
                │                  LLMOps perimeter                 │
                │                                                    │
  request ────▶ │  ┌────────────────┐     ┌───────────────────┐    │ ──▶ response
                │  │ prompt registry │────▶│   model router    │    │
                │  │ (versioned)    │     │ (quality/cost tier)│    │
                │  └───────┬────────┘     └────────┬──────────┘    │
                │          │                       │               │
                │  ┌───────▼────────┐     ┌────────▼──────────┐    │
                │  │ few-shot store │     │   model catalog   │    │
                │  │ (versioned)   │     │  (version + cost) │    │
                │  └───────────────┘     └───────────────────┘    │
                │                                                    │
                │  ┌────────────────────────────────────────────┐  │
                │  │  eval CI gate ◀── output logs ◀── guardrails│  │
                │  └────────────────────────────────────────────┘  │
                └──────────────────────────────────────────────────┘
```

You own more of this perimeter than in a classical ML serving stack. The routing decision, the prompt selection, the eval feedback loop, and the guardrails are all your responsibility — the model vendor owns only the weights.

---

## What MLOps gives you for free

Don't throw out the playbook, just extend it:

- **Data versioning** (DVC, Delta Lake) — still relevant for RAG corpora and fine-tuning datasets.
- **Model registry patterns** — repurpose for a model catalog that tracks cost, latency SLOs, and capability flags per version.
- **Canary deployment** — repurpose for canary prompt rollouts (5% traffic to the new system prompt, watch eval metrics, promote or roll back).
- **Distribution shift monitoring** — still valid, applied to output properties (refusal rate, format validity, semantic similarity to expected answers) rather than input feature statistics.
- **Experiment tracking** (MLflow, W&B) — repurpose for prompt experiments, A/B results, and per-version eval scores.

The tooling changes. The engineering discipline — version everything, test before deploying, monitor in production, have a rollback plan — does not.

---

## Debugging: "it worked yesterday"

The most common support ticket in an LLM-backed product is a quality regression with no obvious error. Nothing throws an exception; the system keeps running; outputs are just *worse*. This is harder to diagnose than a crash because the failure is invisible until you look at it.

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Output format changed (JSON stopped parsing) | Provider auto-updated a floating model alias (`gpt-4`, `claude-3`) to a newer version with different output patterns | Pin to exact model version (`gpt-4-0125-preview`); never use unversioned aliases in production |
| Quality dropped, format unchanged | Prompt drift — someone edited the system prompt in the config DB without a review | Treat prompt edits as code deployments; require a PR + eval run gate before merging |
| Works fine in dev, degrades in production | Few-shot examples differ between environments (hardcoded in dev config, different in prod) | Version few-shot sets as files in the repo alongside the prompt template |
| Regression appears and disappears across days | Non-determinism amplified by a small eval set; you are sampling noise | Evaluate over N≥50 outputs per test case; use `seed` where available; report mean ± std |
| Model refused a valid request it was handling before | Provider updated safety policy with a model version bump | Eval suite must include boundary inputs near the refusal threshold; pin model; run eval after every model update |
| Latency spiked 3× with no code change | Provider silently routed to a slower model variant under the same alias | Log `model` from every API response body, not just the request; alert on p99 latency, not mean |
| Output quality depends on time-of-day | Temperature + live A/B test on the provider's side | Run load-test eval at multiple times; log provider-returned `model` and `usage` fields |

> **War story.** We had a summarization endpoint that had been running cleanly for about three weeks when stakeholder feedback started mentioning "shorter and less detailed summaries." No alerts fired — the service was healthy, latencies were nominal, error rates were zero. I spent a day assuming it was a data distribution shift in the incoming documents. It wasn't. A colleague had updated the system prompt directly in the config table after a demo ("I just tightened the wording a bit"), tested it on two examples, and moved on. The prod config and the repo prompt had silently diverged. The fix was: (1) delete the config-table prompt field and source the prompt exclusively from a versioned file in the repo; (2) add a CI step that runs the eval suite on every prompt file change; (3) require the eval pass rate to be ≥ the last-release baseline before a PR can merge. The deeper fix was accepting that "no code change" and "no prompt change" are orthogonal claims, and only one of them was being verified.

---

## Checkpoint

You're ready to move on when you can, without looking anything up:

1. Name all four dimensions of the LLMOps surface and give a concrete example of a silent, quality-degrading change in each.
2. Explain why `assert output == "Paris"` is the wrong test for an LLM-backed function, and describe two concrete alternatives.
3. State what "prompts as artifacts" means operationally: where do prompts live, who can change them, and what gate is required before a change reaches production.
4. Explain why cost and latency belong in the product spec alongside output quality.
5. Identify the single biggest failure mode in: *"We tested the integration in a notebook with five examples and everything looked great."*
6. List three MLOps practices that transfer directly to LLMOps, and name the adaptation each one needs.

➡ Next up: **Prompt & Model Management** — how to version, A/B test, and route across prompts and models so every change is traceable and every regression is reversible.
