# Evaluation at Scale

> **Module 03 · Course 27** — The most dangerous phase of an LLM project is right after the demo goes well. The examples were cherry-picked, the feedback was verbal, and no one has defined what "working" means in a way a machine can check. By the time you have 10,000 users, "it seemed fine in the demo" is not a baseline you can regress against.

Evaluation is the engineering discipline that makes LLM quality tractable: not perfect, not fully automated, but *measurable* and *comparable across versions*. Without it, every prompt change is a gamble.

---

## Offline eval sets and golden datasets

The foundation of any eval pipeline is a **golden dataset** — a curated set of (input, expected-output) pairs that represent the range of real-world inputs your system will encounter, weighted toward the cases that matter most.

### What makes a good golden dataset

A golden dataset is not "50 examples I thought of on a Friday." It needs:

- **Coverage of the actual input distribution**, including edge cases, short inputs, long inputs, ambiguous inputs, multilingual inputs, and inputs that are close to the refusal boundary.
- **Stable expected outputs** that don't require manual updating every time the product direction changes slightly. Prefer rubric-based expected outputs ("must mention the revenue figure, must be under 150 words") over exact-string expected outputs ("Revenue was $4.2M, up 12%...").
- **A maintenance owner.** Golden datasets rot. New product features, new user behaviors, and new model capabilities make old examples misleading. Someone must own the dataset the same way someone owns the test suite.

### Building the initial set

Three complementary sources:

1. **Mined from production logs** — take real inputs that previously had good (human-rated) outputs. These are the most representative. Sanitize PII before storing.
2. **Adversarial examples** — inputs designed to find failure modes: long inputs, ambiguous queries, inputs with formatting edge cases, inputs in languages you claim to support.
3. **Synthetic from a seed** — generate variations of real inputs using the model itself, then human-review the expected outputs. Efficient but requires careful review to avoid feedback loops.

Target 200–1,000 examples for initial launch, with a plan to grow to 5,000+ as the product matures. Fewer than 100 examples is not enough to detect a 3-5 percentage point regression reliably.

### Contamination and leakage

The eval set must not influence training (for fine-tuned models) or prompt development. If you use eval examples as few-shot examples, you are Goodharting your own benchmark — the eval scores look great because the model is seeing those inputs in the prompt.

Maintain a strict train/eval split. When examples are promoted to few-shot, remove them from the eval set.

---

## Metrics

### Exact match — when and when not

Exact match (`output == expected`) is appropriate when the output is a discrete classification or a structured field with no valid paraphrase:

```python
def exact_match(output: str, expected: str) -> float:
    return 1.0 if output.strip().lower() == expected.strip().lower() else 0.0
```

Appropriate for: named entity extraction with a fixed set, classification labels, yes/no decisions, extracted numbers.

Not appropriate for: summaries, explanations, free-form answers, code (multiple valid implementations), anything where phrasing variation is acceptable.

Using exact match for free-form outputs produces misleadingly low scores and penalizes stylistically valid alternatives.

### Semantic similarity

When paraphrase is acceptable, use embedding-based similarity (cosine distance on sentence embeddings) or BERTScore:

```python
from sentence_transformers import SentenceTransformer, util

model = SentenceTransformer("all-MiniLM-L6-v2")

def semantic_sim(output: str, expected: str) -> float:
    embs = model.encode([output, expected])
    return float(util.cos_sim(embs[0], embs[1]))
```

Thresholds are domain-dependent. 0.85+ is typically "semantically equivalent" for factual summaries; 0.70+ for more creative outputs. Calibrate on a small human-rated sample.

BERTScore (`pip install bert-score`) gives precision, recall, and F1 across token-level alignments — useful when you care about coverage (recall: "does the output contain the key facts?") separately from hallucination control (precision: "is everything in the output supported?").

### Rubric scoring

For complex outputs — multi-step reasoning, long-form writing, structured reports — define a rubric with explicitly weighted criteria:

```python
SUMMARY_RUBRIC = {
    "contains_key_metric": {
        "check": lambda out, meta: meta["key_metric"] in out,
        "weight": 0.40,
    },
    "under_150_words": {
        "check": lambda out, _: len(out.split()) <= 150,
        "weight": 0.20,
    },
    "no_hallucinated_name": {
        "check": lambda out, meta: all(n in meta["source_text"] for n in extract_names(out)),
        "weight": 0.40,
    },
}

def rubric_score(output: str, meta: dict) -> float:
    return sum(
        criterion["weight"] * float(criterion["check"](output, meta))
        for criterion in SUMMARY_RUBRIC.values()
    )
```

Rubrics are explicit, reviewable, and testable — you can unit-test the rubric itself. They require up-front investment in criterion design, but they are far more reliable than hoping an automated judge agrees with your intuitions.

---

## LLM-as-judge

For cases where rubric criteria are hard to express programmatically (subjective quality, coherence, tone appropriateness), use a separate LLM to evaluate outputs. This is **LLM-as-judge**.

### The basic pattern

```python
JUDGE_PROMPT = """
You are a strict evaluator. Score the following summary on a scale of 1-5.

Criteria:
- 5: All key facts present, no hallucinations, appropriate length
- 3: Most facts present, minor issues
- 1: Missing key facts or contains hallucinations

Source document: {source}
Summary: {output}

Return only a JSON object: {{"score": <int>, "reason": "<one sentence>"}}
"""

def judge_output(source: str, output: str, judge_model: str = "gpt-4o") -> dict:
    response = client.chat.completions.create(
        model=judge_model,
        messages=[{"role": "user", "content": JUDGE_PROMPT.format(source=source, output=output)}],
        temperature=0,
        seed=42,
    )
    return json.loads(response.choices[0].message.content)
```

### Biases and mitigations

LLM judges have known systematic biases that can make your eval scores unreliable:

| Bias | Description | Mitigation |
|------|-------------|-----------|
| **Positional bias** | Prefers the first of two options when comparing | Always run both orderings (A vs B and B vs A); use the average |
| **Verbosity bias** | Prefers longer, more detailed outputs regardless of quality | Include length constraints in the rubric; penalize unnecessary verbosity explicitly |
| **Self-preference** | The same model family that generated the output also scores it higher | Use a different model family as judge (GPT outputs judged by Claude, and vice versa) |
| **Leniency drift** | Judge scores creep up over a long eval run as it "gets used to" the format | Interleave calibration examples with known scores throughout the eval set |

**Gold calibration.** Always include a set of gold examples — (input, output, known score) triples where the correct score has been established by human raters — and measure judge accuracy on these before trusting the judge's scores on your eval set:

```python
def calibrate_judge(judge_fn, gold_examples: list[dict]) -> float:
    """Returns fraction of gold examples where judge score is within 1 of human score."""
    hits = sum(
        abs(judge_fn(ex["source"], ex["output"])["score"] - ex["human_score"]) <= 1
        for ex in gold_examples
    )
    return hits / len(gold_examples)
```

A judge that agrees with human raters on fewer than 75% of gold examples should not be trusted for automated CI gates. Use human review instead, or fix the judge prompt first.

---

## Regression suites in CI

The eval suite runs on every pull request that touches a prompt file, a few-shot set, a model pin, or a tool schema. Treating it as a manual step that someone runs occasionally is equivalent to having no eval at all.

### The CI eval gate

```yaml
# .github/workflows/eval.yml (conceptual)
on:
  pull_request:
    paths:
      - "services/*/prompts/**"
      - "services/*/models.yaml"

jobs:
  eval:
    steps:
      - run: python -m pytest tests/eval/ -v --eval-baseline=results/baseline.json
```

The test compares the current run's scores against the stored baseline:

```python
def test_summarizer_eval_regression():
    scores = run_eval(EVAL_SET, model="gpt-4o-0125", prompt_version="HEAD")
    baseline = load_baseline("results/baseline.json")
    
    assert scores["rubric_mean"] >= baseline["rubric_mean"] - 0.02, (
        f"Rubric score regressed: {scores['rubric_mean']:.3f} vs baseline {baseline['rubric_mean']:.3f}"
    )
    assert scores["parse_success_rate"] >= 0.98, (
        f"JSON parse success dropped to {scores['parse_success_rate']:.3f}"
    )
```

**On "what is a passing CI run" for an LLM.** For deterministic checks (parse success, format compliance, rubric criteria that are boolean), you can require 100% pass rate. For score-based metrics, require ≥ baseline − Δ where Δ is calibrated to your noise floor. A Δ of 2 percentage points is typically tight enough to catch regressions while loose enough to not flake on natural variance.

Update the baseline when you *intentionally* improve it — make baseline updates a deliberate, PR-reviewed act, not an automatic "update baseline on every merge."

---

## Human-in-the-loop

Not everything can be automated. Human judgment is necessary when:

- Launching a new product area with no established golden dataset.
- The task requires domain expertise the judge model lacks.
- You're investigating a new failure mode where the rubric criteria are not yet defined.
- The stakes of a false negative (missing a real regression) are high enough to justify the cost.

### Efficient annotation workflows

Annotation is expensive. Make it count:

- **Disagreement sampling.** Only queue examples for human review where two automated metrics disagree (rubric says pass, semantic sim says fail). These are the informative examples.
- **Active learning.** Prioritize examples closest to the decision boundary of your rubric — these update the rubric's calibration most efficiently.
- **Comparative annotation.** "Which of these two outputs is better?" is faster and more reliable than absolute scoring. Use for A/B validation when absolute scores are noisy.

Track inter-annotator agreement. If two human raters agree on fewer than 80% of examples, the task definition is ambiguous — fix the rubric, not the model.

---

## Online eval and feedback

Offline eval tells you how the system performs on your curated set. Online eval tells you how it performs in the wild.

### Implicit signals

Users express quality judgments in behavior, not just explicit ratings:

| Signal | What it indicates |
|--------|------------------|
| Thumbs down / explicit negative rating | Direct quality signal; high precision, low recall |
| "Regenerate" / retry on the same input | User unsatisfied; higher recall than explicit feedback |
| Edit distance from output to final used text | Large edits = poor initial quality |
| Session abandonment after a response | Possible quality failure or irrelevance |
| Copy-paste without edit | High quality for that specific output type |

Log these signals with the trace ID so you can link them back to the specific model version, prompt version, and full call context. This is your production ground truth.

### Online eval as a deployment gate

An A/B prompt rollout doubles as an online eval: route 5% of traffic to the new prompt, compare implicit signal rates between control and treatment in a 48-72 hour window, and promote or roll back based on the comparison. This is the most realistic eval you can run — it uses real users on real tasks — and it is also the highest-stakes, which is why you keep the treatment at 5% until the trend is clear.

---

## Debugging: eval pipeline failures

Eval failures are often as misleading as model failures. A green eval suite can give false confidence; a consistently failing metric can mask a flawed metric rather than a real model problem.

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Eval scores are suspiciously stable across major prompt changes | Eval set is too small or not representative; metric is not sensitive to the changes you're making | Expand the eval set; check that the metric captures the quality dimension you actually care about |
| LLM judge scores everyone 4/5 | Leniency bias; judge prompt lacks specific failure criteria | Add explicit 1-2 score examples to the judge prompt; interleave gold calibration examples during eval |
| Eval score improved, production quality got complaints | Goodharting — you optimized the metric without optimizing the underlying quality | Add implicit signal monitoring to confirm eval improvements transfer to production |
| Eval suite takes 45 minutes, developers skip it | Too many examples evaluated with the most expensive model | Use the small model for 80% of eval runs; use the large model only for nightly full runs and on final PR checks |
| Eval set passes, then fails the next run with no changes | Using `temperature>0` in eval; metric is noisy | Lock `temperature=0` and `seed` for all eval runs; report mean ± std over 3 runs for noisy metrics |
| Newly added examples keep breaking the suite | New examples are too similar to the few-shot set; model "sees" them in the prompt | Enforce train/eval split; check for overlap between new eval examples and current few-shot sets |

> **War story.** Our nightly eval suite showed a steady improvement trend for three months — rubric scores climbing from 0.81 to 0.89 — while production feedback was getting worse. The root cause was a metric that we kept adding edge-case examples to when users complained, without ever adding examples where the model already performed well. The eval set had drifted to represent only the hard cases, so any improvement on those improved the score even as average-case quality degraded. The fix was a population-weighted sample: we pulled 500 random production calls from the last 30 days (with PII stripped), had them rated, and rebuilt the eval set with that distribution. The "improved" scores reset to 0.80 — back to reality — and the trend we saw since then has been an honest signal. Eval set curation is a continuous responsibility, not a one-time task.

---

## Checkpoint

You're ready to move on when you can:

1. Describe three sources for building an initial golden dataset and one contamination risk to guard against in each.
2. Explain when exact match is appropriate as an eval metric and when it is actively misleading.
3. Describe two LLM judge biases and a concrete mitigation for each.
4. Write the assertion in a CI eval test that gates on rubric score regression with a 2-percentage-point tolerance.
5. Explain what "Goodharting a metric" means in the context of LLM eval and describe how you would detect it.
6. Name three implicit online feedback signals and explain what each indicates about output quality.
7. Describe the eval set drift problem and how a population-weighted sample addresses it.

➡ Next up: **Guardrails & Safety** — input/output validation, structured-output enforcement, PII redaction, and prompt-injection defense.
