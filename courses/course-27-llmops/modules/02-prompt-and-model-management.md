# Prompt & Model Management

> **Module 02 · Course 27** — You have a prompt. Right now it probably lives somewhere bad: a string constant in a Python file, a column in a config table, a Notion doc that someone copied into a `.env`. As soon as your system has more than one prompt, more than one model, and more than one person touching them, you have a configuration management problem. This module is how to solve it before it costs you a production incident.

The discipline here is not exotic. It is the same thing you already apply to application code and infrastructure config. The main barrier is that teams tend not to treat prompts as first-class software artifacts until after they've been burned by treating them as anything else.

---

## Versioning prompts

### Prompts as files, not strings

The foundational rule: **prompts live in the repository, not in the database**. That single decision gives you the entire software development lifecycle for free — commit history, diffs, code review, CI gates, rollback via `git revert`.

A prompt is a text file, usually a `.txt` or `.md` or `.jinja2`, committed alongside the code that reads it:

```
services/summarizer/
├── prompts/
│   ├── system.txt          # system role prompt
│   ├── user.jinja2         # user turn template with {{ doc_text }} variable
│   └── few_shot/
│       ├── example_01.json  # { "input": "...", "output": "..." }
│       └── example_02.json
├── main.py
└── tests/
    └── test_summarizer_eval.py
```

The code reads from the file system at startup (or with a hot-reload mechanism if you need it), not from a database. The database pattern seems convenient until your prod and dev prompts diverge silently.

### Template variables

Hardcoding data into a prompt is the same mistake as hardcoding a config value into source code. Use a template engine (Jinja2 is the standard; Python's `str.format()` works for simple cases) to separate structure from data:

```jinja2
{# user.jinja2 #}
Summarize the following document in {{ max_bullets }} bullet points.
Focus on: {{ focus_areas | join(", ") }}.

Document:
---
{{ doc_text }}
---

{% if output_language != "en" %}
Respond in {{ output_language }}.
{% endif %}
```

Variables and their defaults belong in a schema:

```python
@dataclass
class SummarizerParams:
    max_bullets: int = 5
    focus_areas: list[str] = field(default_factory=lambda: ["key findings", "action items"])
    output_language: str = "en"
```

This makes the prompt's parameters explicit, typed, and testable. It also makes A/B testing easier — changing `max_bullets` from 5 to 7 is a parameter change, not a prompt change, and can be rolled out independently.

### Few-shot examples as data files

Few-shot examples are not comments inside the prompt template. They are data, and they drift independently of the template. Version them as separate JSON or YAML files:

```json
{
  "id": "ex_01",
  "version": "2024-11-01",
  "input": "Q3 revenue was $4.2M, up 12% YoY, driven by enterprise renewals...",
  "output": "- Revenue: $4.2M (+12% YoY)\n- Driver: enterprise renewal cohort\n- Risk: SMB churn rate elevated"
}
```

Store a reference in the prompt config, not inline text. When an example becomes stale (your product changes, the expected output format changes), you update the file, the change is tracked in git, and the PR review catches regressions.

---

## A prompt registry

As soon as you have more than one service using LLMs, you need a registry — a single source of truth for every prompt template, few-shot set, and the metadata that makes them manageable:

```
prompt registry schema
──────────────────────
id:            summarizer/system
version:       1.4.2
created_at:    2024-10-15T09:00Z
author:        @aadarsh
status:        active         # active | canary | deprecated
model_compat:  [gpt-4o, claude-3-5-sonnet]
params_schema: SummarizerParams
sha256:        a3f9c1...       # hash of the rendered template at commit
eval_baseline: 0.87            # last measured eval score
```

The registry does not have to be a microservice. A directory of versioned files with a `registry.yaml` index is a legitimate registry for most teams. What matters is the contract: no prompt goes to production without an entry in the registry, and no entry in the registry exists without a corresponding eval baseline.

---

## A/B and canary of prompts

Changing a prompt is a deployment, and deployments need gradual rollout and rollback.

**Traffic splitting.** At the routing layer, split incoming requests between the current prompt version (`control`) and the candidate (`treatment`) by user ID hash or request ID. Store which version served each request alongside the output log.

```python
def select_prompt_version(request_id: str, canary_pct: float = 0.05) -> str:
    # deterministic split based on request_id hash — same request always goes same way
    bucket = int(hashlib.sha256(request_id.encode()).hexdigest(), 16) % 100
    return "treatment" if bucket < (canary_pct * 100) else "control"
```

**Statistical significance.** Do not promote a candidate based on "it looked better on the examples I tested." Collect at least 200–500 samples per variant before comparing eval scores (depending on effect size and metric variance). Use a one-sided t-test or Mann-Whitney U for continuous metrics; binomial proportion test for binary ones.

**Rollback triggers.** Define automatic rollback conditions before you start the canary:

```yaml
canary_policy:
  auto_rollback_if:
    - metric: parse_error_rate
      threshold: 0.05        # 5% json parse failures → immediate rollback
    - metric: eval_score
      threshold: -0.03       # eval drops >3pp below control → rollback after 100 samples
  promote_when:
    - metric: eval_score
      improvement: 0.02      # meaningful improvement
      min_samples: 300
```

---

## Model routing (quality / cost tiers)

Not every request needs your most capable (and most expensive) model. A routing layer classifies the incoming request and selects the appropriate tier:

```
incoming request
      │
      ▼
  classifier (cheap, fast — can be a smaller model or a rules engine)
      │
      ├─ simple extraction / keyword lookup ──▶ tier-1: small model (low cost, fast)
      ├─ structured generation / summarization ▶ tier-2: mid model  (balanced)
      └─ multi-hop reasoning / code generation ▶ tier-3: large model (full capability)
```

The classifier itself can be a small LLM call, a regex/heuristic, or a simple embedding cosine similarity check against representative examples per tier. For most teams, a well-tuned heuristic is cheaper and more reliable than a learned classifier.

**Fallback chains.** Define what happens when a model call fails:

```python
MODEL_CHAIN = [
    ModelConfig(id="gpt-4o", timeout_s=30),
    ModelConfig(id="gpt-4o-mini", timeout_s=15),   # fallback on timeout/500
    ModelConfig(id="claude-3-haiku", timeout_s=15), # fallback on second failure
]
```

Log which tier and which fallback was used for every request. If fallback rates spike, that's a signal about provider health, cost budget exhaustion, or a quota limit — all of which need different responses.

---

## Reproducibility — pinning everything

Reproducibility in LLM systems means being able to regenerate the exact same output distribution given the same inputs. "Exact same" is not achievable with non-zero temperature, but "same distribution" is achievable with full context logging.

**What to pin and log on every call:**

| What | Why it matters |
|------|---------------|
| `model` (exact version, not alias) | `gpt-4` silently upgrades; `gpt-4-0125-preview` does not |
| `temperature`, `top_p`, `max_tokens` | Omitting any of these lets the API use defaults that can change |
| `seed` (where supported) | OpenAI's `seed` param gives *near*-reproducible outputs; log the returned `system_fingerprint` |
| Prompt template version (git SHA or registry version) | So you can reconstruct what was sent |
| Few-shot set version | Independently drifts from the template |
| Retrieved context (for RAG) | Different retrieval = different output, same prompt |

Log all of these as structured metadata on every inference trace. When a user reports bad output and you have a trace ID, you can reconstruct exactly what the model saw.

---

## Debugging: prompt management failures

Prompt management failures are insidious because they don't look like errors. The system stays up, latency is normal, and quality silently degrades. These are the patterns that kill LLM product quality without triggering any alerts.

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Output quality dropped, no code change deployed | Prompt edited in the config DB or admin UI without going through the repo | Move prompt storage to version-controlled files; remove DB edit path entirely |
| Dev and prod have different behavior for the same input | Few-shot examples hardcoded differently in each environment | Version few-shot sets as files in the repo; load from path, not from inline strings |
| Model bumped to new version, outputs changed format | Floating alias (`gpt-4`) resolved to a new model version | Pin to exact model ID; add an integration test that checks output format on every model version change |
| A/B test showed no difference, but anecdotally treatment is better | Too few samples; comparing on the wrong metric | Wait for N≥300 per variant; align the metric to the user outcome you actually care about |
| Eval score dropped after "just a minor rephrasing" | Few-shot examples were tuned for the old phrasing and now poorly match the new template | Update few-shot examples in the same PR as the template change; run eval before merging |
| Promoted a canary that looked good, quality dropped after full rollout | Canary sample was not representative of the full traffic distribution (e.g., only simple inputs were in the test window) | Ensure canary traffic covers edge-case inputs; use stratified sampling if traffic has structure |

> **War story.** A prompt I maintained had a `{{ tone }}` variable that accepted `"formal"` or `"conversational"`. The English output was solid. A localization engineer added support for German by adding a condition at the bottom of the template file — but copied the wrong base template from a Notion document and missed two few-shot examples that had been refined over the previous month. German requests started returning outputs that were technically correct but in the wrong tone for B2B. We caught it three weeks later from a customer escalation. It was a merge conflict that never happened, because the Notion copy and the repo copy had diverged invisibly. The resolution: a single source of truth in git, a language-keyed few-shot directory (`few_shot/de/`, `few_shot/en/`), and a mandatory eval run against each language's eval set on every prompt PR. The process overhead is real; so is the alternative.

---

## Checkpoint

You're ready to move on when you can:

1. Describe the repository layout you would use to version a prompt template, its variables, and its few-shot examples — and explain why the few-shot examples are separate files.
2. Sketch the fields in a minimal prompt registry entry and explain what the `eval_baseline` field is used for.
3. Explain the difference between a prompt parameter change (e.g., `max_bullets: 5 → 7`) and a prompt template change, and why they might warrant different rollout strategies.
4. Write the routing logic that deterministically assigns the same request ID to the same A/B variant on every call, and explain why determinism matters here.
5. List the five things you must log on every LLM call to make outputs reproducible after the fact.
6. Describe the automatic rollback trigger you would set for a canary prompt that generates structured JSON, and justify the threshold.

➡ Next up: **Evaluation at Scale** — how to build the eval pipeline that gates every one of the changes you just learned to manage.
