# Agentic Systems

> **Module 05 · Course 27** — An LLM answering a single question is a calculator. An agent using that same LLM to plan, act, and adapt across multiple steps is a different class of system — with a different class of failure modes. This module builds the mental model and the engineering discipline to ship agents that do not spin forever or silently go wrong.

You already know prompt engineering and basic RAG. Agents are what happens when the model *drives* a control loop instead of just populating a template.

---

## The Agent Loop

The canonical agent architecture is **ReAct** (Reason + Act). The loop is simple in structure and rich in failure modes:

```
THOUGHT  → the model reasons about current state and decides what to do next
  ↓
ACTION   → the model emits a structured tool call (name + arguments)
  ↓
OBSERVATION → tool executes; result is appended to the context
  ↓
THOUGHT  → model re-reasons with the new observation
  ↓
...
  ↓
FINAL ANSWER → loop terminates; result returned to caller
```

ASCII representation of a single-agent run:

```
Caller
  │
  ▼
┌────────────────────────────────────────────────┐
│  Agent Executor                                │
│                                                │
│  context = [system_prompt, user_message, …]    │
│                                                │
│  for step in range(max_steps):                 │
│    response = llm(context, tools=tools)        │  ← one API call per step
│    if response.is_final: break                 │
│    tool_name, args = parse(response)           │
│    result = dispatch[tool_name](**args)        │
│    context.append(tool_call + result)          │
│                                                │
│  return response.content                       │
└────────────────────────────────────────────────┘
```

Each step is one LLM call. Cost scales linearly with steps — and with context growth, because each step sees the full accumulated history. These two facts drive most of the engineering decisions in this module.

The loop terminates on one of three conditions:
1. The model emits a "final answer" — no tool call, just prose.
2. `max_steps` is reached (error / budget exhaustion path).
3. A tool returns a terminal signal and the executor breaks early.

---

## Tool / Function Calling

Modern inference APIs (OpenAI `function_calling`, Anthropic `tool_use`, OpenAI-compatible endpoints) accept a `tools` parameter: a list of JSON Schema descriptors. The model selects zero or more tools, emitting structured JSON rather than free text.

```python
tools = [
    {
        "name": "web_search",
        "description": "Search the web for current information. "
                       "Use this when the question requires up-to-date facts. "
                       "Do NOT use for arithmetic or date math.",
        "parameters": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "Search query string."}
            },
            "required": ["query"]
        }
    },
    {
        "name": "calculator",
        "description": "Evaluate a Python arithmetic expression. "
                       "Use this for any numeric computation.",
        "parameters": {
            "type": "object",
            "properties": {
                "expression": {"type": "string", "description": "A safe Python math expression."}
            },
            "required": ["expression"]
        }
    }
]
```

Your executor dispatches by name:

```python
dispatch = {
    "web_search":  web_search_fn,
    "calculator":  lambda args: str(eval(args["expression"])),
}

for tool_call in response.tool_calls:
    result = dispatch[tool_call.name](**tool_call.input)
    context.append({"role": "tool", "tool_use_id": tool_call.id, "content": result})
```

### Tool Design Rules

| Rule | Rationale |
|------|-----------|
| One responsibility per tool | Fat tools ("do_everything_sql") produce ambiguous routing — the model can't predict side effects, so it hedges by calling more than necessary |
| Descriptions matter more than names | The model routes on the `description` field. Be precise about what triggers a tool and what does not |
| Return structured, terse results | A 10 KB web search result injected raw burns tokens at every subsequent step — summarize before appending |
| Idempotency where it matters | The model will occasionally double-call a tool on ambiguous observations. A non-idempotent tool (deletes, charges) needs an explicit confirmation step |
| Distinguish read from write tools | Makes loop detection and audit logging simpler; lets you sandbox write tools in tests |

---

## Multi-Agent Orchestration

Single-agent loops hit a complexity ceiling: too many tools, tasks that are naturally parallel, or a context window that would blow out mid-run. The answer is to split.

### Supervisor / Worker Pattern

```
┌───────────────────────────────────────────────────────────────┐
│  Supervisor Agent                                             │
│  prompt: "Break the task. Delegate to specialist workers.     │
│           Aggregate their results into a final answer."       │
│                                                               │
│  tools: [delegate_to_worker(worker_id, sub_task)]            │
└──────────────┬──────────────────────────┬────────────────────┘
               │                          │
        ┌──────▼──────────┐      ┌────────▼───────────┐
        │  Worker: coder  │      │  Worker: researcher │
        │  (runs tests,   │      │  (web search, docs) │
        │   edits files)  │      │                     │
        └─────────────────┘      └─────────────────────┘
```

`delegate_to_worker` is itself a tool. It spawns a child agent, runs it to completion, and returns only the final answer — not the child's internal reasoning — back to the supervisor. The supervisor context stays lean.

### Orchestration Patterns Compared

| Pattern | Mechanics | Best for |
|---------|-----------|----------|
| **Subagent (sync)** | Supervisor calls a function that runs the worker inline, returns result | Short sequential sub-tasks; result needed before next step |
| **Hand-off (async)** | Supervisor emits a structured message; worker picks up from a queue | Long-running tasks; each worker independently retryable |
| **Parallel fan-out** | Executor issues multiple `delegate` calls concurrently | Independent sub-tasks (fetch three URLs, grade three essays) |
| **Reflection** | A second LLM call critiques and scores the first's output before returning | High-stakes outputs where a wrong answer is costly |

### State Ownership

The hardest design question in multi-agent systems: **who owns conversation history?**

- **Shared context** — every agent appends to a single thread. Simple to implement, grows without bound. Works for < 5 agents and < 10 total steps.
- **Isolated contexts with summaries** — each agent has its own context; the supervisor passes structured summaries between agents. More boilerplate, dramatically cheaper and more reliable at scale.
- **Persistent state store** — agents write intermediate results to a key-value store (Redis, a DB row); a new agent can be spawned from checkpoint without replaying the full history. Required for multi-hour or multi-day workflows.

---

## Memory

Every agent run operates on a three-layer memory stack:

| Layer | Scope | Implementation | Persistence |
|-------|-------|----------------|-------------|
| **Working memory** | This run only | The in-context message list | Lost on run end |
| **Episodic / short-term** | Session or recent runs | Sliding-window summary; recent-history store | Minutes to days |
| **Long-term / semantic** | Permanent facts, preferences | Vector DB (FAISS, pgvector, Qdrant); keyed retrieval | Permanent |

### Vector Memory in Practice

```python
# storing a memory
embedding = embed_fn("User prefers concise answers without worked examples")
vector_store.upsert(
    id="user_pref_1",
    vector=embedding,
    metadata={"text": "User prefers concise answers without worked examples",
              "updated_at": "2025-10-01"}
)

# retrieval at query time — inject into system prompt
hits = vector_store.query(embed_fn(user_message), top_k=3)
injected = "\n".join(h["text"] for h in hits)
system_prompt = f"{base_system}\n\n# Relevant memories:\n{injected}"
```

Two failure modes to watch:

1. **Stale memories.** A fact written six months ago is retrieved and asserted as current truth. Add `updated_at` to metadata; expire or down-weight facts older than a threshold.
2. **Embedding model drift.** Swap your embedding model and old vectors are no longer comparable to new queries. Re-embed the entire store, or pin the embedding endpoint version and track it separately from the LLM version.

---

## Loop & Cost Control

An agent free to call tools indefinitely is an agent free to spend indefinitely. Three mechanisms protect you.

### 1. Hard step limit

```python
MAX_STEPS = 15

for step in range(MAX_STEPS):
    response = llm(context, tools=tools)
    if response.is_final:
        break
    _dispatch_and_append(response, context)
else:
    raise AgentBudgetExceeded(f"No final answer within {MAX_STEPS} steps")
```

Always raise on exhaustion. Silently returning the last intermediate observation as an answer is worse than a clear error — the caller has no way to distinguish "done" from "gave up."

### 2. Token budget

Most APIs return `usage` on every response. Track cumulative tokens and intervene before you hit the hard wall:

```python
SOFT_LIMIT = 40_000   # inject "wrap up" instruction
HARD_LIMIT = 50_000   # stop

cumulative_tokens = 0

for step in range(MAX_STEPS):
    response = llm(context, tools=tools)
    cumulative_tokens += response.usage.total_tokens

    if cumulative_tokens >= HARD_LIMIT:
        raise AgentBudgetExceeded("Token budget exhausted")
    if cumulative_tokens >= SOFT_LIMIT and not _warned:
        context.append({"role": "system",
                        "content": "You are running low on tokens. Produce a final answer now, even if incomplete."})
        _warned = True
    if response.is_final:
        break
    _dispatch_and_append(response, context)
```

### 3. Loop detection

A common failure: the model calls the same tool with identical arguments twice in a row. It received a result it could not synthesize and is retrying rather than reasoning. Detect and abort:

```python
from collections import deque
import json

recent_sigs = deque(maxlen=3)

def check_and_record_call(tool_name: str, args: dict) -> None:
    sig = (tool_name, json.dumps(args, sort_keys=True))
    if sig in recent_sigs:
        raise AgentLoopDetected(f"Repeated tool call detected: {tool_name}({args})")
    recent_sigs.append(sig)
```

A window of 3 is conservative — a legitimate retry-on-transient-error workflow should use a separate retry mechanism with exponential back-off, not the main loop.

---

## Determinism & Testing Agents

Agents are non-deterministic by nature (temperature > 0, model sampling). Your test suite must not be. The solution: **mock the LLM call**.

### A Minimal Mock Client

```python
# tests/mock_llm.py
from dataclasses import dataclass, field
from typing import List, Any

@dataclass
class FakeToolCall:
    name: str
    input: dict
    id: str = "tc_0"

@dataclass
class FakeUsage:
    total_tokens: int = 100

@dataclass
class FakeResponse:
    tool_calls: List[FakeToolCall] = field(default_factory=list)
    content: str = ""
    is_final: bool = False
    usage: Any = field(default_factory=FakeUsage)

class ScriptedLLM:
    """Returns pre-scripted responses in order; asserts no unexpected extra calls."""

    def __init__(self, responses: List[FakeResponse]):
        self._queue = list(responses)

    def complete(self, messages, tools=None) -> FakeResponse:
        if not self._queue:
            raise AssertionError("ScriptedLLM: called more times than scripted responses")
        return self._queue.pop(0)
```

Tests then script the exact conversation:

```python
def test_agent_calls_tool_then_answers():
    llm = ScriptedLLM([
        FakeResponse(tool_calls=[FakeToolCall("calculator", {"expression": "2+2"})]),
        FakeResponse(content="The answer is 4.", is_final=True),
    ])
    agent = Agent(llm=llm, tools={"calculator": lambda args: str(eval(args["expression"]))})
    result = agent.run("What is 2+2?")
    assert result == "The answer is 4."


def test_agent_raises_on_max_steps():
    llm = ScriptedLLM([
        FakeResponse(tool_calls=[FakeToolCall("web_search", {"query": "something"})]) for _ in range(20)
    ])
    agent = Agent(llm=llm, tools={"web_search": lambda args: "no result"}, max_steps=5)
    with pytest.raises(AgentBudgetExceeded):
        agent.run("Keep searching forever")


def test_loop_detection_raises():
    identical = FakeToolCall("web_search", {"query": "same query"})
    llm = ScriptedLLM([FakeResponse(tool_calls=[identical]) for _ in range(5)])
    agent = Agent(llm=llm, tools={"web_search": lambda args: "meh"}, max_steps=10)
    with pytest.raises(AgentLoopDetected):
        agent.run("this will loop")
```

For integration tests against a real model, capture raw API responses once and store as fixtures. Replay them in CI. Re-record only when you intentionally change prompts — treat fixture changes as a signal that observable agent behavior has changed.

---

## Debugging Agentic Systems

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Agent calls the same tool repeatedly until `max_steps` | Loop: model received a result it cannot synthesize; may be low-quality tool output or an ambiguous system prompt | Add loop detection (identical call signature); improve the system prompt: "If a tool returns no new information, stop retrying and synthesize what you have" |
| Agent calls tool A when B is clearly correct | Routing failure: tool descriptions overlap or are too vague; tool ordering in the list biases selection | Rewrite descriptions to make the decision boundary explicit; test with randomized tool list order |
| `context_length_exceeded` after many steps | Context bloat: raw tool results accumulate unabridged in the message list | Summarize tool results before appending; use isolated-context multi-agent design for long tasks |
| Different answer on identical input in CI | Temperature > 0 or a non-deterministic tool (`datetime.now()`, `random`) | Set `temperature=0` for test-deterministic workflows; mock time and random in unit tests; use record/replay fixtures for integration tests |
| Agent terminates with a partial answer, caller treats it as final | Executor swallows `AgentBudgetExceeded` and returns last intermediate observation | Surface exhaustion explicitly — raise an exception or return a structured `{"status": "incomplete", "reason": "budget_exceeded"}` |
| Tool returns successfully but agent ignores the result | Tool result appended with wrong message role; API role contract violated | OpenAI requires `role: "tool"`; Anthropic requires `role: "user"` + `tool_result` content block — read the API spec for the role your client is targeting |

> **War story.** A production research agent had `max_steps=50` and was hitting it on roughly 30% of queries. The on-call response was to raise the limit to 100. Cost doubled in two days. The root cause: the system prompt read "keep searching until you find a definitive answer" — the model had no instruction to synthesize partial results. The fix was one sentence: "If two consecutive searches return no information you haven't already seen, stop and summarize what you have." Average steps per run dropped from 43 to 9. Raising the limit had been treating a symptom. The lesson: **agent behavior is controlled by the system prompt at least as much as by executor code.** Tune the prompt before tuning the limits.

---

## Checkpoint

You're ready for the challenges when you can, without looking anything up:

1. Draw the ReAct loop and name the three conditions that terminate it.
2. Explain why a broad tool description causes routing failures more than a broad tool implementation does.
3. Describe the difference between the hand-off and subagent orchestration patterns and give one concrete reason to choose each.
4. Name the three memory layers (working / episodic / long-term), state what each is backed by, and explain what happens to working memory when the run ends.
5. Write the pseudocode for a token-budget check that injects a "wrap up" system message at 80% of budget and hard-stops at 100%.
6. Implement a loop detector that raises `AgentLoopDetected` on three consecutive identical tool call signatures in a sliding window.
7. Explain exactly why `ScriptedLLM` makes an agent test deterministic, and what you must do when you intentionally change the system prompt.
8. Name the two message role values that OpenAI and Anthropic respectively require for tool results, and state what happens when you get them wrong.

➡ Next up: **Serving & Cost Economics** — a correct agent that runs at $10/query will not survive its first sprint review.
