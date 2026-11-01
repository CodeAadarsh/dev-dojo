# Observability for LLMs

> **Module 07 · Course 27** — Every distributed system needs observability. LLMs need more of it, because the failure modes are subtle: the model doesn't crash, it just quietly gives worse answers. This module covers tracing an LLM request end-to-end, logging without leaking PII, detecting output drift before your users file tickets, and building dashboards that actually tell you when something is wrong.

The mental model throughout: treat each LLM call as a **span** in a distributed trace, the same way you'd trace a database query or an HTTP call to a downstream service. The primitives are the same; the attributes are different.

---

## Tracing a Request End-to-End

A minimal LLM trace captures these attributes on every call:

```
Span: llm.complete
  ├── trace_id          (correlation with the parent request)
  ├── request_id        (unique per LLM call — useful for provider support tickets)
  ├── model             ("claude-3-haiku-20240307")
  ├── prompt_tokens     (int)
  ├── completion_tokens (int)
  ├── total_tokens      (int)
  ├── latency_ms        (wall clock, client side)
  ├── ttft_ms           (time-to-first-token, streaming only)
  ├── cost_usd          (computed from token counts × model pricing)
  ├── finish_reason     ("end_turn" | "max_tokens" | "stop_sequence" | "tool_use")
  ├── tool_calls[]      (name + input for each tool called)
  └── error             (null or exception class + message)
```

For RAG pipelines, add retrieval attributes to the same span or a child span:

```
Span: retrieval.query
  ├── query_embedding_model
  ├── retrieved_chunks      (count)
  ├── top_score             (cosine similarity of best hit)
  ├── retrieval_latency_ms
  └── collection_name
```

For agentic runs, each step is a child span nested under the run span:

```
Span: agent.run (root)
  ├── run_id
  ├── total_steps
  ├── total_tokens
  ├── total_cost_usd
  ├── outcome           ("completed" | "budget_exceeded" | "loop_detected" | "error")
  │
  ├── Span: agent.step[0]
  │     ├── step_index: 0
  │     ├── tool_call: web_search({"query": "..."})
  │     ├── tool_latency_ms
  │     └── tokens_this_step
  │
  └── Span: agent.step[1]
        ├── step_index: 1
        ├── finish_reason: "end_turn"
        └── tokens_this_step
```

### Instrumenting with OpenTelemetry

OpenTelemetry is the standard. Wrap your LLM client:

```python
from opentelemetry import trace
from opentelemetry.trace import SpanKind
import time

tracer = trace.get_tracer("llm.service")

def traced_llm_call(messages: list, model: str, **kwargs) -> dict:
    with tracer.start_as_current_span(
        "llm.complete",
        kind=SpanKind.CLIENT,
    ) as span:
        start = time.monotonic()
        try:
            response = llm_client.complete(messages=messages, model=model, **kwargs)
            usage = response.usage
            span.set_attribute("llm.model", model)
            span.set_attribute("llm.prompt_tokens", usage.input_tokens)
            span.set_attribute("llm.completion_tokens", usage.output_tokens)
            span.set_attribute("llm.latency_ms", int((time.monotonic() - start) * 1000))
            span.set_attribute("llm.cost_usd", _compute_cost(model, usage))
            span.set_attribute("llm.finish_reason", response.stop_reason)
            return response
        except Exception as exc:
            span.record_exception(exc)
            span.set_status(trace.StatusCode.ERROR, str(exc))
            raise

def _compute_cost(model: str, usage) -> float:
    # prices per million tokens — update when providers change rates
    prices = {
        "claude-3-haiku-20240307": (0.25, 1.25),
        "claude-sonnet-4-5":       (3.00, 15.00),
    }
    inp, out = prices.get(model, (5.0, 15.0))
    return (usage.input_tokens * inp + usage.output_tokens * out) / 1_000_000
```

---

## Logging & Redaction

### What to log

Log enough to reproduce and investigate any run later:

| Field | Log it? | Notes |
|-------|---------|-------|
| Trace ID, request ID | Yes | Critical for correlation |
| Model, version | Yes | Required for cost attribution and regression detection |
| Token counts, cost | Yes | Core metrics |
| Finish reason | Yes | `max_tokens` finish is often a bug |
| Tool names + input keys | Yes (keys only, not values) | Values may contain PII |
| Prompt text | Configurable | See PII redaction below |
| Completion text | Configurable | See PII redaction below |
| User ID (hashed) | Yes (hashed) | For per-user cost attribution without PII linkage |

### PII Redaction

Prompt and completion logging is a compliance decision, not just an engineering one. Before logging raw text:

1. **Classify first.** Tag each prompt template with a data-sensitivity level at design time. A "summarize this support ticket" prompt may contain customer names; a "classify this error code" prompt probably doesn't.
2. **Redact before writing.** Use a redaction library (`presidio`, `scrubadub`, a regex-based scanner) on the text before emitting it to your log pipeline.
3. **Log hashes for dedup/correlation without storing plaintext.** `sha256(prompt_text)` lets you detect repeated identical prompts and measure cache hit rates without storing the text.

```python
import hashlib
from presidio_analyzer import AnalyzerEngine
from presidio_anonymizer import AnonymizerEngine

analyzer = AnalyzerEngine()
anonymizer = AnonymizerEngine()

def redact(text: str) -> str:
    results = analyzer.analyze(text=text, language="en")
    return anonymizer.anonymize(text=text, analyzer_results=results).text

def log_prompt(prompt: str, sensitive: bool = True) -> dict:
    return {
        "prompt_hash": hashlib.sha256(prompt.encode()).hexdigest()[:16],
        "prompt_text": redact(prompt) if sensitive else prompt,
        "prompt_len": len(prompt),
    }
```

---

## Output Drift Detection

This is the uniquely hard observability problem for LLMs: the model keeps responding, logs show no errors, users are mildly unhappy — and you have no signal.

Output drift manifests as:

- Answers that were concise become verbose (or vice versa after a model update).
- Structured JSON output starts failing schema validation at a 5% rate.
- Sentiment of generated text shifts (a summarizer starts sounding negative).
- Hallucination rate increases after a system prompt change.

### Structural Checks (always-on, cheap)

For any output that has a defined schema or format, validate it automatically:

```python
import json

def check_json_output(completion: str, schema: dict) -> dict:
    try:
        parsed = json.loads(completion)
        # validate against schema (jsonschema, pydantic, etc.)
        validate(parsed, schema)
        return {"valid": True, "error": None}
    except (json.JSONDecodeError, ValidationError) as e:
        return {"valid": False, "error": str(e)}

# log these as a metric
metrics.increment("llm.output.json_valid" if result["valid"] else "llm.output.json_invalid")
```

Track the invalidity rate over time. A 2% parse failure rate that was 0.1% last week is a regression.

### Statistical Drift Detection

For open-ended text outputs, track distributional properties over time:

| Signal | How to measure | Alert threshold |
|--------|----------------|-----------------|
| **Output length** | `len(completion.split())` → percentiles | p50 shifts > 20% week-over-week |
| **Embedding distance from baseline** | Embed completions; track cosine distance from a reference set | Rolling mean distance > 2σ from baseline |
| **Toxicity / safety scores** | Run a cheap classifier on all outputs (Perspective API, or a local model) | Rate of flagged outputs > N× baseline |
| **Schema validation fail rate** | Structural check above | > 1% for strictly structured outputs |

```python
from collections import deque
import statistics

WINDOW = 1000
output_lengths = deque(maxlen=WINDOW)
baseline_mean = None
baseline_stdev = None

def update_drift_detector(completion: str):
    output_lengths.append(len(completion.split()))
    if len(output_lengths) < WINDOW:
        return
    mean = statistics.mean(output_lengths)
    stdev = statistics.stdev(output_lengths)
    if baseline_mean and abs(mean - baseline_mean) > 2 * baseline_stdev:
        alert(f"Output length drift: mean={mean:.0f}, baseline={baseline_mean:.0f}")
```

Establish the baseline during a known-good period and recalibrate when you intentionally change the model or prompt.

### LLM-as-Judge for Quality Metrics

For quality signals that structural checks cannot capture (factual correctness, helpfulness), use a second LLM to grade a sample:

```python
JUDGE_PROMPT = """Rate the following LLM response on a scale of 1–5 for helpfulness and factual accuracy.
Reply with exactly: SCORE: <1-5>

User question: {question}
LLM response: {response}
"""

def score_sample(question: str, response: str) -> int:
    result = cheap_model.complete(JUDGE_PROMPT.format(
        question=question, response=response
    ))
    match = re.search(r"SCORE:\s*([1-5])", result.content)
    return int(match.group(1)) if match else None
```

Sample 5–10% of production traffic and track the rolling mean score. An LLM judge is not perfectly calibrated, but it detects large regressions reliably.

---

## Feedback Capture

Human feedback is the ground truth that LLM-as-judge approximates. Capture it at every touchpoint:

| Signal | How to capture | Latency to actionable data |
|--------|----------------|---------------------------|
| **Thumbs up/down** | Log `{response_id, user_id_hash, rating: +1/-1}` | Hours (volume-dependent) |
| **Edit feedback** | When a user rewrites a generated response, diff the original and edit | Hours |
| **Explicit corrections** | "That's wrong, the answer is X" as a follow-up message | Hours |
| **Task completion rate** | Did the user complete their goal after this response? | Days |
| **Copy/paste rate** | Did the user copy the response? (browser telemetry) | Hours |

Link every feedback event back to the original trace via `response_id`. This is why the trace ID must be propagated all the way to the client-side feedback widget.

```python
# When the user clicks thumbs down
feedback_store.insert({
    "response_id": response_id,           # links to the LLM trace
    "session_id": session_id,
    "rating": -1,
    "timestamp": now_utc(),
    # do NOT store user_id in plaintext — hash it
    "user_id_hash": sha256(user_id)[:16],
})
```

---

## Dashboards & Alerts

### Core Dashboard Panels

A minimum viable LLM observability dashboard has four sections:

**1. Volume & Cost**
- Requests/min (rate)
- Tokens/min (input + output, separate lines)
- Cost/hour (running total, by model tier)
- Cost per request (p50/p95)

**2. Latency**
- TTFT p50/p95/p99
- E2E latency p50/p95/p99
- Latency by model (overlay)

**3. Quality Signals**
- LLM-as-judge score: rolling 7-day mean + today
- Schema validation fail rate (%)
- Output length distribution (p50/p95)
- Thumbs-down rate (%)

**4. Errors & Anomalies**
- `finish_reason = max_tokens` rate (truncated responses)
- API error rate by type (rate_limit, timeout, context_length)
- Drift detector alerts (output length, embedding distance)

### Alert Thresholds (starting points — tune to your baseline)

| Alert | Condition | Urgency |
|-------|-----------|---------|
| Cost spike | Cost/hour > 2× trailing 7-day average | P2 — investigate within 1 hour |
| Quality regression | LLM-judge score < 7-day mean − 0.5 pts for 30 min | P2 |
| Schema validation failure | Fail rate > 2% over 15 min | P1 — structured output is broken |
| High truncation rate | `finish_reason=max_tokens` > 10% over 30 min | P3 — `max_tokens` too tight |
| Context-length overflow | `context_length_exceeded` errors > 0 | P2 — runaway context in agent or conversation |
| API error rate | Error rate > 5% for 5 min | P1 — provider or network issue |

---

## Debugging LLM Observability Problems

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Quality regressions reported by users but no metric moved | No quality metrics instrumented; thumbs-down volume too low to detect; LLM-judge sampling rate too low | Add LLM-as-judge on a 10% sample; lower the minimum volume threshold on alerting; add edit-rate telemetry |
| "Bad output" report but can't find the original trace | `response_id` not propagated from LLM call to client and back with feedback | Pass `response_id` in the API response; front end must include it in every feedback event |
| Cost attribution shows "other" for 40% of spend | LLM calls not tagged with feature/team/user context; shared API key across multiple services | Add `x-feature-id` and `x-team-id` headers or span attributes; use separate API keys per service |
| Drift detector fires constantly with false positives | Baseline established during an atypical traffic period (weekend, post-launch spike); threshold too tight | Re-establish baseline during a representative steady-state period; widen threshold to 3σ |
| Schema validation fail rate suddenly 100% | System prompt or output instructions changed; model version changed; new code path bypasses the formatter | Check recent deployments; diff the system prompt in the trace against last known-good; verify formatter is applied on all code paths |
| Thumbs-down rate spikes on Mondays only | Batch job runs over the weekend and processes stale data; or a weekly scheduled model re-evaluation changes the routing | Correlate spike with deployment and cron job logs; add a "data freshness" attribute to LLM traces for RAG-based responses |

> **War story.** A production summarization feature at SAP ran for three months with no quality alerts firing. Usage was growing steadily. Then a user emailed: "The summaries have been one-sentence long for weeks." The investigation found that a system prompt change six weeks earlier had accidentally prepended "Be extremely concise." Output length metrics existed but were not alerted on — the team was watching p99, which was still reasonable, and missed that p50 had dropped from 120 words to 18 words. The fix was a 3-minute prompt revert. The lesson: **you need both mean and percentile tracking on output signals, and a week-over-week comparison alert.** p99 staying stable while p50 collapses is a common silent regression pattern with LLMs, because the model still handles edge cases at length but truncates routine cases.

---

## Checkpoint

You're ready for the challenges when you can, without looking anything up:

1. List every attribute you would set on an `llm.complete` span (model, tokens, cost, latency, finish_reason, tool_calls, error) and explain why `finish_reason` is a quality signal, not just metadata.
2. Describe the three-tier PII handling strategy (classify at design time, redact before write, hash for correlation) and explain why logging a hash instead of plaintext still gives you cache hit rate data.
3. Name four structural and statistical drift signals for LLM outputs and state a concrete alert threshold for each.
4. Explain the "LLM-as-judge" approach: what it measures, what cheap model you'd use, what sampling rate is practical, and what it cannot detect.
5. Describe how to link a user's thumbs-down click back to the original LLM trace, including which IDs must be propagated and in which direction.
6. State the three alert conditions that should be P1 (immediate response) and explain why schema validation failure is P1 while a quality score drop is P2.
7. Diagnose the "bad output but no trace" problem: which two pieces of data must flow from the LLM call, through the API response, and back with the feedback event?
8. Explain the war-story failure mode: why did watching p99 output length miss a p50 regression, and what specific alert would have caught it within 24 hours?

➡ Course complete — you've covered LLMOps end-to-end: eval & regression, guardrails, agentic systems, serving economics, and observability. The challenges ahead apply these under time pressure, with deterministic verifiers so there is no ambiguity about whether you got it right.
